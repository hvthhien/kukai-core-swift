//
//  LedgerService.swift
//  
//
//  Created by Simon Mcloughlin on 17/09/2021.
//

import Foundation
import KukaiCryptoSwift
import JavaScriptCore
import CoreBluetooth
import Combine
import os.log



/**
A service class to wrap up all the complicated interactions with CoreBluetooth and the modified version of ledgerjs, needed to communicate with a Ledger Nano X.

Ledger only provide a ReactNative module for third parties to integrate with. The architecture of the module also makes it very difficult to
integrate with native mobile (if it can be packaged up) as it relies heavily on long observable chains passing through many classes and functions.
To overcome this, I copied the base logic from multiple ledgerjs classes into a single typescript file and split the functions up into more of a utility style class, where
each function returns a result, that must be passed into another function. This allowed the creation of a swift class to sit in the middle of these
functions and decide what to do with the responses.

The modified typescript can be found in this file (under a fork of the main repo) https://github.com/simonmcl/ledgerjs/blob/native-mobile/packages/hw-app-tezos/src/NativeMobileTezos.ts .
The containing package also includes a webpack file, which will package up the typescript and its dependencies into mobile friendly JS file, which
needs to be included in the swift project. Usage of the JS can be seen below.

**NOTE:** this modified typescript is Tezos only as I was unable to find a way to simply subclass their `Transport` class, to produce a re-usable
NativeMobile transport. The changes required modifiying the app and other class logic which became impossible to refactor back into the project, without rewriting everything.
*/
public class LedgerService: NSObject, CBPeripheralDelegate, CBCentralManagerDelegate {
	
	// MARK: - Types / Constants
	
	/// Ledger UUID constants
	struct LedgerNanoXConstant {
		static let serviceUUID = CBUUID(string: "13d63400-2c97-0004-0000-4c6564676572")
		static let notifyUUID = CBUUID(string: "13d63400-2c97-0004-0001-4c6564676572")
		static let writeUUID = CBUUID(string: "13d63400-2c97-0004-0002-4c6564676572")
	}
	
	/// Instead of returning data, sometimes ledger returns a code to indicate that so far the message have been received successfully
	public static let successCode = "9000"
	
	/// General Ledger error codes, pulled from the source, and some additional ones added for native swift issues
	public enum GeneralErrorCodes: String, Error, Codable {
		case PIN_REMAINING_ATTEMPTS = "63c0"
		case INCORRECT_LENGTH = "6700"
		case MISSING_CRITICAL_PARAMETER = "6800"
		case COMMAND_INCOMPATIBLE_FILE_STRUCTURE = "6981"
		case SECURITY_STATUS_NOT_SATISFIED = "6982"
		case CONDITIONS_OF_USE_NOT_SATISFIED = "6985"
		case INCORRECT_DATA = "6a80"
		case NOT_ENOUGH_MEMORY_SPACE = "6a84"
		case REFERENCED_DATA_NOT_FOUND = "6a88"
		case FILE_ALREADY_EXISTS = "6a89"
		case INCORRECT_P1_P2 = "6b00"
		case INS_NOT_SUPPORTED = "6d00"
		case CLA_NOT_SUPPORTED = "6e00"
		case TECHNICAL_PROBLEM = "6f00"
		case MEMORY_PROBLEM = "9240"
		case NO_EF_SELECTED = "9400"
		case INVALID_OFFSET = "9402"
		case FILE_NOT_FOUND = "9404"
		case INCONSISTENT_FILE = "9408"
		case ALGORITHM_NOT_SUPPORTED = "9484"
		case INVALID_KCV = "9485"
		case CODE_NOT_INITIALIZED = "9802"
		case ACCESS_CONDITION_NOT_FULFILLED = "9804"
		case CONTRADICTION_SECRET_CODE_STATUS = "9808"
		case CONTRADICTION_INVALIDATION = "9810"
		case CODE_BLOCKED = "9840"
		case MAX_VALUE_REACHED = "9850"
		case GP_AUTH_FAILED = "6300"
		case LICENSING = "6f42"
		case HALTED = "6faa"
		
		case DEVICE_LOCKED = "009000"
		case UNKNOWN = "99999999"
		case NO_WRITE_CHARACTERISTIC = "99999996"
	}
	
	/// Dedicated error codes pulled from the Ledger tezos app
	public enum TezosAppErrorCodes: String, Error, Codable {
		case EXC_WRONG_PARAM = "6B00"
		case EXC_WRONG_LENGTH = "6C00"
		case EXC_INVALID_INS = "6D00"
		case EXC_WRONG_LENGTH_FOR_INS = "917E"
		case EXC_REJECT = "6985"
		case EXC_PARSE_ERROR = "9405"
		case EXC_REFERENCED_DATA_NOT_FOUND = "6A88"
		case EXC_WRONG_VALUES = "6A80"
		case EXC_SECURITY = "6982"
		case EXC_HID_REQUIRED = "6983"
		case EXC_CLASS = "6E00"
		case EXC_MEMORY_ERROR = "9200"
	}
	
	/// Used to keep track of what request the user is making to the Ledger, as we have to pass through many many different fucntions / callbacks
	private enum RequestType {
		case address
		case signing
		case none
	}
	
	
	
	
	
	// MARK: - Properties
	
	private let jsContext: JSContext
	private var centralManager: CBCentralManager?
	private var connectedDevice: CBPeripheral?
	private var writeCharacteristic: CBCharacteristic?
	private var notifyCharacteristic: CBCharacteristic?
	
	private var requestedUUID: String? = nil
	private var requestType: RequestType = .none
	private var deviceList: [String: String] = [:] {
		didSet {
			deviceListPublisher.send(deviceList)
		}
	}
	
	/// Be notified when the ledger device returns a success message, part way through the process.
	/// This can be useful to indicate to users that the request has succeed, but s waiting on input on the Ledger device to continue
	@Published public var partialSuccessMessageReceived: Bool = false
	
	@Published private var bluetoothSetup: Bool = false
	
	private var receivedAPDU_statusCode = PassthroughSubject<String, Never>()
	private var receivedAPDU_payload = PassthroughSubject<String, Never>()
	
	private var writeToLedgerSubject = PassthroughSubject<String, Never>()
	private var deviceListPublisher = PassthroughSubject<[String: String], ErrorResponse>()
	private var deviceConnectedPublisher = PassthroughSubject<Bool, ErrorResponse>()
	private var addressPublisher = PassthroughSubject<(address: String, publicKey: String), ErrorResponse>()
	private var signaturePublisher = PassthroughSubject<String, ErrorResponse>()
	
	private var bag_connection = Set<AnyCancellable>()
	private var bag_writer = Set<AnyCancellable>()
	private var bag_apdu = Set<AnyCancellable>()
	private var counter = 0
	
	/// Public shared instace to avoid having multiple copies of the underlying `JSContext` created
	public static let shared = LedgerService()
	
	
	
	
	
	// MARK: - Init
	
	private override init() {
		jsContext = JSContext()
		jsContext.exceptionHandler = { context, exception in
			os_log("Ledger JSContext exception: %@", log: .kukaiCoreSwift, type: .error, exception?.toString() ?? "")
		}
		
		
		// Grab the custom ledger tezos app js and load it in
		if let jsSourcePath = Bundle.module.url(forResource: "ledger_app_tezos", withExtension: "js", subdirectory: "External") {
			do {
				let jsSourceContents = try String(contentsOf: jsSourcePath)
				self.jsContext.evaluateScript(jsSourceContents)
				
			} catch (let error) {
				os_log("Error parsing Ledger javascript file: %@", log: .kukaiCoreSwift, type: .error, "\(error)")
			}
		}
		
		super.init()
		
		
		// Register a native function, to be passed into the js functions, that will write chunks of data to the device
		let nativeWriteHandler: @convention(block) (String, Int) -> Void = { [weak self] (apdu, expectedNumberOfAPDUs) in
			os_log("Inside nativeWriteHandler", log: .ledger, type: .debug)
			
			// Keep track of the number of times its called for each request
			self?.counter += 1
			
			
			// Convert the supplied data into an APDU. Returns a single string per ADPU, but broken up into chunks, seperated by spaces for each maximum sized data packet
			guard let sendAPDU = self?.jsContext.evaluateScript("ledger_app_tezos.sendAPDU(\"\(apdu)\", 156)").toString() else {
				self?.deviceConnectedPublisher.send(false)
				return
			}
			
			
			// Add the APDU chunked string to be added to the write subject
			self?.writeToLedgerSubject.send(sendAPDU)
			
			
			// When all messages recieved, call completion to trigger the messages one by one
			if self?.counter == expectedNumberOfAPDUs {
				self?.writeToLedgerSubject.send(completion: .finished)
				self?.counter = 0
			}
		}
		let nativeWriteHandlerBlock = unsafeBitCast(nativeWriteHandler, to: AnyObject.self)
		jsContext.setObject(nativeWriteHandlerBlock, forKeyedSubscript: "nativeWriteData" as (NSCopying & NSObjectProtocol))
		
		
		// Setup a JS ledger tezos app, bound to the nativeWriteHandler
		let _ = jsContext.evaluateScript("""
			var nativeTransport = new ledger_app_tezos.NativeTransport(nativeWriteData)
			var tezosApp = new ledger_app_tezos.Tezos(nativeTransport)
		""")
	}
	
	
	
	
	
	// MARK: - Public functions
	
	/**
	Setup the bluetooth manager, ready to scan or connect to devices
	*/
	private func setupBluetoothConnection() -> Future<Bool, Never> {
		if centralManager != nil {
			return Just(true).asFuture()
		}
		
		centralManager = CBCentralManager(delegate: self, queue: nil)
		return $bluetoothSetup.dropFirst().asFuture()
	}
	
	/**
	Start listening for ledger devices
	 - returns: Publisher with a dictionary of `[UUID: deviceName]` or an `ErrorResponse`
	*/
	public func listenForDevices() -> AnyPublisher<[String: String], ErrorResponse> {
		self.deviceListPublisher = PassthroughSubject<[String: String], ErrorResponse>()
		
		self.setupBluetoothConnection()
			.sink { [weak self] value in
				if !value {
					self?.deviceListPublisher.send(completion: .failure(ErrorResponse.unknownError()))
				}
				
				self?.centralManager?.scanForPeripherals(withServices: [LedgerNanoXConstant.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
				self?.bag_connection.removeAll()
			}
			.store(in: &self.bag_connection)
		
		return self.deviceListPublisher.eraseToAnyPublisher()
	}
	
	/**
	Stop listening for and reporting new ledger devices found
	*/
	public func stopListening() {
		self.centralManager?.stopScan()
		self.deviceListPublisher.send(completion: .finished)
	}
	
	/**
	Connect to a ledger device by a given UUID
	 - returns: Publisher which will indicate true / false, or return an `ErrorResponse` if it can't connect to bluetooth
	*/
	public func connectTo(uuid: String) -> AnyPublisher<Bool, ErrorResponse> {
		if self.connectedDevice != nil, self.connectedDevice?.identifier.uuidString == uuid {
			return AnyPublisher.just(true)
		}
		
		self.setupBluetoothConnection()
			.sink { [weak self] value in
				if !value {
					self?.deviceConnectedPublisher.send(completion: .failure(ErrorResponse.unknownError()))
				}
				
				self?.requestedUUID = uuid
				self?.centralManager?.scanForPeripherals(withServices: [LedgerNanoXConstant.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
				self?.bag_connection.removeAll()
			}
			.store(in: &self.bag_connection)
		
		return self.deviceConnectedPublisher.eraseToAnyPublisher()
	}
	
	/**
	Disconnect from the current Ledger device
	 - returns: A Publisher with a boolean, or `ErrorResponse` if soemthing goes wrong
	*/
	public func disconnectFromDevice() {
		if let device = self.connectedDevice {
			self.centralManager?.cancelPeripheralConnection(device)
		}
	}
	
	/**
	Get the UUID of the connected device
	 - returns: a string if it can be found
	*/
	public func getConnectedDeviceUUID() -> String? {
		return self.connectedDevice?.identifier.uuidString
	}
	
	/**
	Get a TZ address and public key from the current connected Ledger device
	- parameter forDerivationPath: Optional. The derivation path to use to extract the address from the underlying HD wallet
	- parameter curve: Optional. The `EllipticalCurve` to use to extract the address
	- parameter verify: Whether or not to ask the ledger device to prompt the user to show them what the TZ address should be, to ensure the mobile matches
	- returns: A publisher which will return a tuple containing the address and publicKey, or an `ErrorResponse`
	*/
	public func getAddress(forDerivationPath derivationPath: String = HD.defaultDerivationPath, curve: EllipticalCurve = .ed25519, verify: Bool) -> AnyPublisher<(address: String, publicKey: String), ErrorResponse> {
		self.setupWriteSubject()
		self.requestType = .address
		
		var selectedCurve = 0
		switch curve {
			case .ed25519:
				selectedCurve = 0
				
			case .secp256k1:
				selectedCurve = 1
		}
		
		let _ = jsContext.evaluateScript("tezosApp.getAddress(\"\(derivationPath)\", {verify: \(verify), curve: \(selectedCurve)})")
		
		// return the addressPublisher, but listen for the returning of values and use this as an oppertunity to clean up the lingering cancellables, as it only returns one at a time
		return addressPublisher.onReceiveOutput({ _ in
			self.bag_apdu.removeAll()
			self.bag_writer.removeAll()
		}).eraseToAnyPublisher()
	}
	
	/**
	Sign an operation payload with the underlying secret key, returning the signature
	- parameter hex: An operation converted to JSON, forged and watermarked, converted to a hex string. (Note: there are some issues with the ledger app signing batch transactions. May simply return no result at all. Can't run REVEAL and TRANSACTION together for example)
	- parameter forDerivationPath: Optional. The derivation path to use to extract the address from the underlying HD wallet
	- parameter parse: Ledger can parse non-hashed (blake2b) hex data and display operation data to user (e.g. transfer 1 XTZ to TZ1abc, for fee: 0.001). There are many limitations around what can be parsed. Frequnetly it will require passing in false
	- returns: A Publisher which will return a string containing the hex signature, or an `ErrorResponse`
	*/
	public func sign(hex: String, forDerivationPath derivationPath: String = HD.defaultDerivationPath, parse: Bool) -> AnyPublisher<String, ErrorResponse>  {
		self.setupWriteSubject()
		self.signaturePublisher = PassthroughSubject<String, ErrorResponse>()
		self.requestType = .signing
		
		let _ = jsContext.evaluateScript("tezosApp.signOperation(\"\(derivationPath)\", \"\(hex)\", \(parse))")
		
		// return the addressPublisher, but listen for the returning of values and use this as an oppertunity to clean up the lingering cancellables, as it only returns one at a time
		return signaturePublisher.onReceiveOutput({ _ in
			self.bag_apdu.removeAll()
			self.bag_writer.removeAll()
		}).eraseToAnyPublisher()
	}
	
	
	
	
	
	// MARK: - Bluetooth
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func centralManagerDidUpdateState(_ central: CBCentralManager) {
		os_log("centralManagerDidUpdateState", log: .ledger, type: .debug)
		self.bluetoothSetup = (central.state == .poweredOn)
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
		
		// If we have been requested to connect to a speicific UUID, only listen for that one and connect immediately if found
		if let requested = self.requestedUUID, peripheral.identifier.uuidString == requested {
			os_log("Found requested ledger UUID, connecting ...", log: .ledger, type: .debug)
			
			self.connectedDevice = peripheral
			self.centralManager?.connect(peripheral, options: ["requestMTU": 156])
			self.centralManager?.stopScan()
		
		// Else if we haven't been requested to find a specific one, store each unique device and fire a delegate callback, until scan stopped manually
		} else if self.requestedUUID == nil, deviceList[peripheral.identifier.uuidString] == nil {
			os_log("Found a new ledger device. Name: %@, UUID: %@", log: .ledger, type: .debug, peripheral.name ?? "-", peripheral.identifier.uuidString)
			
			self.deviceList[peripheral.identifier.uuidString] = peripheral.name ?? ""
		}
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
		os_log("Connected to %@, %@", log: .ledger, type: .debug, peripheral.name ?? "", peripheral.identifier.uuidString)
		
		// record the connected device and set LedgerService as the delegate. Don't report successfully connected to ledgerService.delegate until
		// we have received the callbacks for services and characteristics. Otherwise we can't use the device
		self.connectedDevice = peripheral
		self.connectedDevice?.delegate = self
		self.connectedDevice?.discoverServices([LedgerNanoXConstant.serviceUUID])
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
		os_log("Failed to connect to %@, %@", log: .ledger, type: .debug, peripheral.name ?? "", peripheral.identifier.uuidString)
		self.connectedDevice = nil
		self.deviceConnectedPublisher.send(false)
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
		guard let services = peripheral.services else {
			os_log("Unable to locate services for: %@, %@. Error: %@", log: .ledger, type: .debug, peripheral.name ?? "", peripheral.identifier.uuidString, "\(String(describing: error))")
			self.connectedDevice = nil
			self.deviceConnectedPublisher.send(false)
			return
		}
		
		for service in services {
			if service.uuid == LedgerNanoXConstant.serviceUUID {
				peripheral.discoverCharacteristics(nil, for: service)
				return
			}
		}
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
		guard let characteristics = service.characteristics else {
			os_log("Unable to locate characteristics for: %@, %@. Error: %@", log: .ledger, type: .debug, peripheral.name ?? "", peripheral.identifier.uuidString, "\(String(describing: error))")
			self.connectedDevice = nil
			self.deviceConnectedPublisher.send(false)
			return
		}
		
		for characteristic in characteristics {
			if characteristic.uuid == LedgerNanoXConstant.writeUUID {
				os_log("Located write characteristic", log: .ledger, type: .debug)
				writeCharacteristic = characteristic
				
			} else if characteristic.uuid == LedgerNanoXConstant.notifyUUID {
				os_log("Located notify characteristic", log: .ledger, type: .debug)
				notifyCharacteristic = characteristic
			}
			
			if let _ = writeCharacteristic, let notify = notifyCharacteristic {
				os_log("Registering for notifications on notify characteristic", log: .ledger, type: .debug)
				peripheral.setNotifyValue(true, for: notify)
				
				self.deviceConnectedPublisher.send(true)
				return
			}
		}
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
		if let err = error {
			os_log("Error during write: %@", log: .ledger, type: .debug, "\( err )")
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			
		} else {
			os_log("Successfully wrote to write characteristic", log: .ledger, type: .debug)
		}
	}
	
	/// CBCentralManagerDelegate function, must be marked public because of protocol definition
	public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
		guard characteristic.uuid == LedgerNanoXConstant.notifyUUID else {
			return
		}
		
		os_log("Receiveing value from notify characteristic", log: .ledger, type: .debug)
		
		
		// Extract the payload, convert it to an APDU so the result can be extracted
		let hexString = characteristic.value?.toHexString() ?? "-"
		let receivedResult = jsContext.evaluateScript("""
			var result = ledger_app_tezos.receiveAPDU(\"\(hexString)\")
			
			if (result.error === "null") {
				result.data
			} else {
				"Error: " + result.error
			}
		""")
		
		
		// Check for issues
		guard let resultString = receivedResult?.toString(), String(resultString.prefix(5)) != "Error" else {
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			return
		}
		
		
		if resultString.count <= 6 {
			os_log("Received APDU Status code", log: .ledger, type: .debug)
			receivedAPDU_statusCode.send(resultString)
			
			if resultString == LedgerService.successCode {
				partialSuccessMessageReceived = true
			}
			
			return
			
		} else {
			os_log("Received APDU Payload", log: .ledger, type: .debug)
			receivedAPDU_payload.send(resultString)
			return
		}
	}
	
	
	
	
	
	// MARK: - Private helpers
	
	/// Setup the listeners to the `writeToLedgerSubject` that will ultimately return results to the developers code
	private func setupWriteSubject() {
		self.writeToLedgerSubject = PassthroughSubject<String, Never>()
		self.addressPublisher = PassthroughSubject<(address: String, publicKey: String), ErrorResponse>()
		self.signaturePublisher = PassthroughSubject<String, ErrorResponse>()
		
		// Tell write subject to wait for completion message
		self.writeToLedgerSubject
			.collect()
			.sink { [weak self] apdus in
				guard let self = self, let writeChar = self.writeCharacteristic else {
					os_log("setupWriteSubject - couldn't find self/write", log: .ledger, type: .error)
					return
					
				}
				
				
				// go through APDU chunked strings and convert into Deferred Futures, that don't execute any code until subscribed too
				var futures: [Deferred<Future<String?, ErrorResponse>>] = []
				for apdu in apdus {
					futures.append(self.sendAPDU(apdu: apdu, writeCharacteristic: writeChar))
				}
				
				
				// Convert array of deferred futures into a single concatenated publisher.
				// When subscribed too, it will wait for one piblisher to finish, before assigning subscriber to next.
				// This allows us to run the code for + send each APDU and wait a response from the device, before moving to the next APDU.
				// This allows us to catch errors when they first occur, and return immeidately, instead of firing error for each APDU packet, causing UI issues
				guard let concatenatedPublishers = futures.concatenatePublishers() else {
					os_log("setupWriteSubject - unable to create concatenatedPublishers", log: .ledger, type: .error)
					return
				}
				
				
				// Get the result of the concatenated publisher, whether it be successful payload, or error
				concatenatedPublishers
					.last()
					.convertToResult()
					.sink { concatenatedResult in
						
						guard let res = try? concatenatedResult.get() else {
							let error = (try? concatenatedResult.getError()) ?? ErrorResponse.unknownError()
							os_log("setupWriteSubject - received error: %@", log: .ledger, type: .debug, "\(error)")
							self.returnErrorResponseToPublisher(errorResponse: error)
							return
						}
						
						os_log("setupWriteSubject - received value: %@", log: .ledger, type: .debug, "\( res )")
						switch self.requestType {
							case .address:
								self.convertAPDUToAddress(payload: res)
								
							case .signing:
								self.convertAPDUToSignature(payload: res)
							
							case .none:
								os_log("Received a value, but no request type set", log: .ledger, type: .error)
						}
					}
					.store(in: &self.bag_writer)
			}
			.store(in: &bag_writer)
	}
	
	/// Create a Deferred Future to send a single APDU and respond with a success / failure based on the result of the notify characteristic
	private func sendAPDU(apdu: String, writeCharacteristic: CBCharacteristic) -> Deferred<Future<String?, ErrorResponse>> {
		return Deferred {
			Future<String?, ErrorResponse> { [weak self] promise in
				guard let self = self else {
					os_log("sendAPDU - couldn't find self", log: .ledger, type: .error)
					promise(.failure(ErrorResponse.unknownError()))
					return
				}
				
				// String is split by spaces, write each componenet seperately to the bluetooth queue
				let components = apdu.components(separatedBy: " ")
				for component in components {
					if component != "" {
						let data = (try? Data(hexString: component)) ?? Data()
						
						os_log("sendAPDU - writing payload", log: .ledger, type: .debug)
						self.connectedDevice?.writeValue(data, for: writeCharacteristic, type: .withResponse)
					}
				}
				
				
				// Listen for responses
				self.receivedAPDU_statusCode.sink { statusCode in
					if statusCode == LedgerService.successCode {
						os_log("sendAPDU - received success statusCode", log: .ledger, type: .debug)
						promise(.success(nil))
						
					} else {
						os_log("sendAPDU - received error statusCode: %@", log: .ledger, type: .error, statusCode)
						promise(.failure( self.errorResponseFrom(statusCode: statusCode) ))
						
					}
				}
				.store(in: &self.bag_apdu)
				
				
				self.receivedAPDU_payload.sink { payload in
					os_log("sendAPDU - received payload: %@", log: .ledger, type: .debug, payload)
					promise(.success(payload))
				}
				.store(in: &self.bag_apdu)
			}
		}
	}
	
	/// Take in a payload string from an APDU, and call the necessary JS function to convert it to an address / publicKey. Also will fire to the necessary publisher
	private func convertAPDUToAddress(payload: String?) {
		guard let payload = payload else {
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			return
		}
		
		guard let dict = jsContext.evaluateScript("ledger_app_tezos.convertAPDUtoAddress(\"\(payload)\")").toObject() as? [String: String] else {
			os_log("Didn't receive address object", log: .ledger, type: .error)
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			return
		}
		
		guard let address = dict["address"], let publicKey = dict["publicKey"] else {
			if let err = dict["error"] {
				os_log("Internal script error: %@", log: .ledger, type: .error, err)
				returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
				
			} else {
				os_log("Unknown error", log: .ledger, type: .error)
				returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			}
			return
		}
		
		self.addressPublisher.send((address: address, publicKey: publicKey))
	}
	
	/// Take in a payload string from an APDU, and call the necessary JS function to convert it to a signature. Also will fire to the necessary publisher
	private func convertAPDUToSignature(payload: String?) {
		guard let payload = payload else {
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			return
		}
		
		guard let resultHex = jsContext.evaluateScript("ledger_app_tezos.convertAPDUtoSignature(\"\(payload)\").signature").toString() else {
			os_log("Didn't receive signature", log: .ledger, type: .error)
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
			return
		}
		
		if resultHex != "" && resultHex != "undefined" {
			self.signaturePublisher.send(resultHex)
			self.signaturePublisher.send(completion: .finished)
			
		} else {
			os_log("Unknown error. APDU: %@", log: .ledger, type: .error, resultHex)
			returnErrorToPublisher(statusCode: GeneralErrorCodes.UNKNOWN.rawValue)
		}
	}
	
	/// Create and error response from a statusCode
	private func errorResponseFrom(statusCode: String) -> ErrorResponse {
		os_log("Error parsing data. statusCode: %@", log: .ledger, type: .error, statusCode)
		
		var code = GeneralErrorCodes.UNKNOWN.rawValue
		var type: Error = GeneralErrorCodes.UNKNOWN
		
		if let tezosCode = TezosAppErrorCodes(rawValue: statusCode) {
			code = tezosCode.rawValue
			type = tezosCode
			
		} else if let generalCode = GeneralErrorCodes(rawValue: statusCode) {
			code = generalCode.rawValue
			type = generalCode
		}
		
		return ErrorResponse.ledgerError(code: code, type: type)
	}
	
	/// A helper to take an error code , returned from an APDU, and fire it back into whichever publisher is currently being listened too
	private func returnErrorToPublisher(statusCode: String) {
		let errorResponse = errorResponseFrom(statusCode: statusCode)
		returnErrorResponseToPublisher(errorResponse: errorResponse)
	}
	
	/// Send the error into the appropriate publisher
	private func returnErrorResponseToPublisher(errorResponse: ErrorResponse) {
		switch requestType {
			case .address:
				self.addressPublisher.send(completion: .failure(errorResponse))
			
			case .signing:
				self.signaturePublisher.send(completion: .failure(errorResponse))
			
			case .none:
				os_log("Requesting error for unknown requestType: %@", log: .ledger, type: .error, "\(errorResponse)")
		}
	}
}
