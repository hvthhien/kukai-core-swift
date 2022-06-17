//
//  ErrorHandlingService.swift
//  KukaiCoreSwift
//
//  Created by Simon Mcloughlin on 27/01/2021.
//  Copyright © 2021 Kukai AB. All rights reserved.
//

import Foundation
import os.log



/*
 Changes
 
 - split into:
	- RPC errors
	- system errors
		- e.g. no internet connection
	- internal application errors
		- e.g. another Error enum from somewhere else in the app
 
 
 - if RPC
	- Just denote it is RPC
	- The error string
	- Short hand for display (remove protocol)
	- usual data for logging/debugging
 
 - if system
	- denote its system
	- but also its sub type (no internet, request time out etc)
	- need some readable string
 - usual data for logging/debugging
 
 - if internal application error
	- denote its internal
	- have a subtype for the actual error
	- some way to get string
	- usual data for logging/debugging
 */


public enum ErrorType: String {
	case rpc
	case system
	case network(Int)
	case internalApplication
}

public struct ErrorTest: CustomStringConvertible, Error {
	
	let errorType: ErrorType
	
	let subType: Error?
	
	let rpcErrorString: String?
	
	/// The requested URL that returned the error
	public var requestURL: URL?
	
	/// The JSON that was sent as part of the request
	public var requestJSON: String?
	
	/// The raw JSON that was returned
	public var responseJSON: String?
	
	/// The HTTP status code returned
	public var httpStatusCode: Int?
	
	
	
	// MARK: - Constructors
	
	public static func rpcError(rpcErrorString: String) -> ErrorTest {
		return ErrorTest(errorType: .rpc, subType: nil, rpcErrorString: rpcErrorString, requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil)
	}
	
	public static func systemError(subType: Error) -> ErrorTest {
		return ErrorTest(errorType: .system, subType: subType, rpcErrorString: nil, requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil)
	}
	
	public static func networkError(statusCode: Int) -> ErrorTest {
		return ErrorTest(errorType: .network(statusCode), subType: subType, rpcErrorString: nil, requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil)
	}
	
	public static func internalApplicationError(error: Error) -> ErrorTest {
		return ErrorTest(errorType: .internalApplication, subType: error, rpcErrorString: nil, requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil)
	}
	
	public static func fromOperationError(_ opError: OperationResponseInternalResultError) -> ErrorTest {
		let errorWithoutProtocol = opError.id.removeLeadingProtocolFromRPCError()
		
		if errorWithoutProtocol == "michelson_v1.runtime_error", let withError = opError.with {
			
			if let failwith = withError.int, let failwithInt = Int(failwith) {
				// Smart contract failwith reached with an Int denoting an error code
				// Liquidity baking error codes, need to consider how to incorporate: https://gitlab.com/dexter2tz/dexter2tz/-/blob/liquidity_baking/dexter.liquidity_baking.mligo#L85
				return ErrorTest.rpcError(rpcErrorString: "A FAILWITH instruction was reached: {\"int\": \(failwithInt)}")
				
			} else if let failwith = withError.string {
				// Smart contract failwith reached with an String error message
				return ErrorTest.rpcError(rpcErrorString: "A FAILWITH instruction was reached: {\"string\": \(failwith)}")
				
			} else if let args = withError.args {
				// Smart Contract failwith reached with a dictionary
				return ErrorTest.rpcError(rpcErrorString: "A FAILWITH instruction was reached: {\"args\": \(args)}")
				
			} else {
				// Unknown smart contract error
				return ErrorTest.rpcError(rpcErrorString: "michelson_v1.runtime_error")
			}
			
		} else {
			return ErrorTest(errorType: .rpc, subType: nil, rpcErrorString: errorWithoutProtocol, requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil)
		}
	}
	
	public static func searchForSystemError(data: Data?, response: URLResponse?, networkError: Error?, requestURL: URL, requestData: Data?) -> ErrorTest {
		
		// Check if we got an error object (e.g. no internet connection)
		if let networkError = networkError {
			return ErrorTest.systemError(subType: networkError)
		}
		// Check if we didn't get an error object, but instead got a non http 200 (e.g. 404)
		else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
			return ErrorTest.networkError(statusCode: httpResponse.statusCode)
		}
		
		return nil
	}
	
	
	
	// MARK: - Modifiers
	
	public mutating func addNetworkData(requestURL: URL?, requestJSON: String?, responseJSON: String?, httpStatusCode: Int?) {
		self.requestURL = requestURL
		self.requestJSON = requestJSON
		self.responseJSON = responseJSON
		self.httpStatusCode = httpStatusCode
	}
	
	
	
	// MARK: - Display
	
	/// Prints the underlying error type with either an RPC string, or an underlying Error object contents
	public var description: String {
		get {
			switch errorType {
				case .rpc:
					return "Error - RPC: \(rpcErrorString?.removeLeadingProtocolFromRPCError() ?? rpcErrorString)"
					
				case .system:
					return "Error - System: \(subType)"
					
				case .network(let statusCode):
					return "Error - Network: \(statusCode)"
					
				case .internalApplication:
					return "Error - Internal Application: \(subType)"
			}
		}
	}
}












// MARK: - Types

/// High level error types, used to quickly categoise Tezos or system errors, in order to display error messages to user
public enum ErrorResponseType: String, Codable {
	case unknownError
	case unknownWallet
	case unknownBalance
	case unknownParseError
	case internalApplicationError
	
	case noInternetConnection
	case requestTimeOut
	case tooManyRedirects
	case atsUnsecureConnection
	
	case gasExhausted
	case storageExhausted
	
	case exchangeDataOutOfSync
	case exchangeHigherThanZero
	case insufficientFunds
	case insufficientFundsDelegation
	case delegationUnchanged
	case emptyTransaction
	case invalidAddress
	case bakerCantDelegate
	case invalidBaker
	case exchangeTimeout
	case exchangeNotEnoughFa
	case exchangeNotEnoughTez
	
	case tokenToTokenUnavailable
	case counterError
	case dexterNotEnoughFA
	case dexterNotEnoughTez
	
	case ledgerError
}



/**
This library deals with Errors in many forms that are cumbersome to handle in client applications if passed directly.
This object seeks to wrap up all the necessary data into a single source of truth and provide access to all the necessary pieces of information
*/
public struct ErrorResponse: CustomStringConvertible, Error {
	
	/// The requested URL that returned the error
	public var requestURL: URL?
	
	/// The JSON that was sent as part of the request
	public var requestJSON: String?
	
	/// The raw JSON that was returned
	public var responseJSON: String?
	
	/// The HTTP status code returned
	public var httpStatusCode: Int?
	
	/// The raw Swift error object returned (e.g. to indicate the internet connection is offline, codable failed etc.)
	public var errorObject: Error?
	
	/// A meaningful string containing error information (e.g. in some cases a full string version of a swift error, as opposed to `Error.localizedDescription` which usually contains nothing useful)
	public var errorString: String?
	
	/// An enum to help differeniate high level error catgeories, to quickly and easily display generic error messages to users
	public var errorType: ErrorResponseType
	
	/// Returns detailed error info inside a string, denoting whether it was a network related error, or an internal application error (e.g. couldn't find a file).
	public var description: String {
		get {
			if let requestURL = requestURL {
				return "ErrorResponse - Network: Type: \(errorType), StatusCode: \(httpStatusCode ?? -1), \nURL: \(requestURL), \nRequest: \(requestJSON ?? ""), \nResponse: \(responseJSON ?? ""), \nErrorObject: \(ErrorResponse.errorToString(errorObject))"
			} else {
				return "ErrorResponse - Application: Type: \(errorType), Error: \(String(describing: errorObject)), ErrorString: \(errorString ?? "")"
			}
		}
	}
	
	
	
	
	
	// MARK: - Init
	
	/**
	Create an instance of `ErrorResponse` with the ability to set every property
	*/
	public init(requestURL: URL?, requestJSON: String?, responseJSON: String?, httpStatusCode: Int?, errorObject: Error?, errorString: String?, errorType: ErrorResponseType) {
		self.requestURL = requestURL
		self.requestJSON = requestJSON
		self.responseJSON = responseJSON
		self.httpStatusCode = httpStatusCode
		self.errorObject = errorObject
		self.errorString = errorString
		self.errorType = errorType
	}
	
	/**
	Helper to quickly create an instance of `ErrorResponse` with just a string and a type
	- parameter string: useful error information as a string
	- parameter errorType: enum indicating the type of error
	- returns `ErrorResponse`
	*/
	public static func error(string: String, errorType: ErrorResponseType) -> ErrorResponse {
		return ErrorResponse(requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil, errorObject: nil, errorString: string, errorType: errorType)
	}
	
	/**
	Helper to quickly create an instance of `ErrorResponse` indicating an internal application error (e.g. couldn't find file, invalid URL etc.)
	- parameter error: the error object indicating the issue
	- returns `ErrorResponse`
	*/
	public static func internalApplicationError(error: Error) -> ErrorResponse {
		return ErrorResponse(requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil, errorObject: error, errorString: errorToString(error), errorType: .internalApplicationError)
	}
	
	/**
	Helper to quickly create an instance of `ErrorResponse` indicating an unknown parsing error occured. (e.g. invalid JSON, wrong model, missing data etc)
	- parameter error: the error object thrown by JSONCoder or JSONSerialisation
	- returns `ErrorResponse`
	*/
	public static func unknownParseError(error: Error) -> ErrorResponse {
		return ErrorResponse(requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil, errorObject: nil, errorString: errorToString(error), errorType: .unknownParseError)
	}
	
	/**
	Helper to quickly create an instance of `ErrorResponse` to use as a fallback for cases wihere the issue is a rare occurence that doesn't fit into one of the main types
	- parameter error: the error object thrown by JSONCoder or JSONSerialisation
	- returns `ErrorResponse`
	*/
	public static func unknownError() -> ErrorResponse {
		return ErrorResponse(requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil, errorObject: nil, errorString: nil, errorType: .unknownError)
	}
	
	/**
	Helper to quickly create an instance of `ErrorResponse` to use to encapsulate errors from Ledger devices
	- parameter code: the hexadecimal code returned by ledger
	- parameter type: the matching string type
	- returns `ErrorResponse`
	*/
	public static func ledgerError(code: String, type: Error) -> ErrorResponse {
		return ErrorResponse(requestURL: nil, requestJSON: nil, responseJSON: nil, httpStatusCode: nil, errorObject: type, errorString: code, errorType: .ledgerError)
	}
	
	/**
	Certian versions of iOS have issues calling  "\(error)". Return that if possible, or anything else avilable if not
	- parameter error: the error object to convert
	- returns full error object as a string
	*/
	public static func errorToString(_ error: Error?) -> String {
		guard let err = error else {
			return ""
		}
		
		if #available(iOS 13.0, *) {
			return "\(err)"
		} else {
			return "\(err.localizedDescription): \(err.userInfo)"
		}
	}
}





// MARK: - Service class

/// A class used to process errors into more readable format, and optionally notifiy a global error handler of every error occuring
public class ErrorHandlingService {
	
	
	// MARK: - Properties
	
	/// Shared instance so that it can hold onto an event closure
	public static let shared = ErrorHandlingService()
	
	/// Called everytime an error is parsed. Extremely useful to track / log errors globally, in order to run logic or record to external service
	public var errorEventClosure: ((ErrorResponse) -> Void)? = nil
	
	private init() {}
	
	
	
	// MARK: - Error parsers
	
	/**
	Take in a string and check if it contains a known error string, if so parse into an `ErrorResponse` object.
	Errors from the Tezos RPC will come down inside a large block of JSON, with the error being a string containing the protocol version that the server was running,
	some other technical info depending on the circumstances and then a string constant detailing the type of error. THis function was created primarily to just take those
	error strings and check to see which constant was present inside it. Its now grown to be more of a general purpose error catcher.
	- parameter string: A string containing some kind of error, whether it be from Tezos RPC or a string version of a Swift error object
	- parameter andLong: A bool used to decide whether or not to trigger a console log and the global event callback. Tezos responses often include many errors, some of which are extremely generic. In some cases we will run this function many times on one response and only log the meaningful error we care about.
	- returns `ErrorResponse`
	*/
	public class func parse(string: String, andLog: Bool = true) -> ErrorResponse {
		var errorResponse: ErrorResponse = ErrorResponse.unknownError()
		
		// General errors
		if string.contains("balance_too_low") {
			errorResponse = ErrorResponse.error(string: string, errorType: .insufficientFunds)
			
		} else if (string.contains("Counter") && string.contains("already used for contract")) || string.contains("counter_in_the_past") {
			errorResponse = ErrorResponse.error(string: string, errorType: .counterError)
			
		} else if string.contains("The Internet connection appears to be offline.") || string.contains("A data connection is not currently allowed.") {
			errorResponse = ErrorResponse.error(string: string, errorType: .noInternetConnection)
			
		} else if string.contains("The request timed out.") {
			errorResponse = ErrorResponse.error(string: string, errorType: .requestTimeOut)
			
		} else if string.contains("too many HTTP redirects") {
			errorResponse = ErrorResponse.error(string: string, errorType: .tooManyRedirects)
			
		} else if string.contains("App Transport Security policy requires the use of a secure connection") {
			errorResponse = ErrorResponse.error(string: string, errorType: .atsUnsecureConnection)
			
		} else if string.contains("gas_exhausted") {
			errorResponse = ErrorResponse.error(string: string, errorType: .gasExhausted)
			
		} else if string.contains("storage_exhausted") {
			errorResponse = ErrorResponse.error(string: string, errorType: .storageExhausted)
			
		} else if string.contains("implicit.empty_implicit_contract") 	// No XTZ
					|| string.contains("\"NotEnoughBalance\"") { 		// No FA1.2 for Dexter swap
			
			errorResponse = ErrorResponse.error(string: string, errorType: .insufficientFunds)
			
		} else if string.contains("storage_limit_too_high") {
			errorResponse = ErrorResponse.error(string: string, errorType: .unknownError)
			
		} else if string.contains("NOW is greater than deadline") {
			errorResponse = ErrorResponse.error(string: string, errorType: .exchangeTimeout)
			
		} else if string.contains("storage_error") {
			// Belive this to be an issue caused when the account doesn't have enough balance left to pay the burn fee needed to update the contract storage
			errorResponse = ErrorResponse.error(string: string, errorType: .insufficientFunds)
			
		}  else if string.contains("delegate.unchanged") {
			errorResponse = ErrorResponse.error(string: string, errorType: .delegationUnchanged)
			
		} else if string.contains("empty_transaction") {
			errorResponse = ErrorResponse.error(string: string, errorType: .emptyTransaction)
			
		} else if string.contains("delegate.no_deletion") {
			errorResponse = ErrorResponse.error(string: string, errorType: .bakerCantDelegate)
			
		} else if string.contains("contract.manager.unregistered_delegate") {
			errorResponse = ErrorResponse.error(string: string, errorType: .invalidBaker)
			
		} else if string.contains("Unhandled error (Failure \"Invalid contract notation.\")") {
			errorResponse = ErrorResponse.error(string: string, errorType: .invalidAddress)
			
		} else if string.contains("Failed to parse the request body: No case matched:") {
			errorResponse = ErrorResponse.error(string: string, errorType: .invalidAddress)
		}
		
		// Dexter errors
		else if string.contains("tokensBought is less than minTokensBought")
					|| string.contains("xtzBought is less than minXtzBought") {
			
			errorResponse = ErrorResponse.error(string: string, errorType: .exchangeDataOutOfSync)
			
		} else if string.contains("minTokensBought must be greater than zero")
					|| string.contains("minXtzBought must be greater than zero")
					|| string.contains("Amount must be greater than zero") {
			
			errorResponse = ErrorResponse.error(string: string, errorType: .exchangeHigherThanZero)
			
		} else if string.contains("NOW is greater than deadline") {
			errorResponse = ErrorResponse.error(string: string, errorType: .exchangeTimeout)
			
		} else if string.contains("xtzPool must be greater than zero") {
			errorResponse = ErrorResponse.error(string: string, errorType: .exchangeNotEnoughTez)
			
		} else if string.contains("tokenPool must be greater than zero") {
			errorResponse = ErrorResponse.error(string: string, errorType: .exchangeNotEnoughFa)
			
		} else if string.contains("Amount must be zero") {
			errorResponse = ErrorResponse.error(string: string, errorType: .unknownError)
			
		} else if string.contains("tokensSold is zero") {
			errorResponse = ErrorResponse.error(string: string, errorType: .unknownError)
		}
		
		if andLog { logAndCallback(withErrorResponse: errorResponse) }
		return errorResponse
	}
	
	/**
	Helper method to wrap around `parse(string: ...)` in order to process generic network responses.
	- parameter data: A data object returned from URLSession task
	- parameter response: A URLResponse returned from URLSession task
	- parameter networkError: A swift error object returned by the URLSession task
	- parameter requestURL: The URL that was requested
	- parameter requestData: The request Data() that was sent to the URL
	- returns `ErrorResponse`
	*/
	public class func parse(data: Data?, response: URLResponse?, networkError: Error?, requestURL: URL, requestData: Data?) -> ErrorResponse? {
		var errorResponse: ErrorResponse? = nil
		
		// Some RPC errors don't come in JSON format.
		// For example its possible that a Http 400 might include a string stack trace indicating that the destination address is invalid.
		// Attempt to parse the body as a string and process
		
		if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
			if let d = data {
				errorResponse = parse(string: String(data: d, encoding: .utf8) ?? "", andLog: false)
				
			} else if let err = networkError {
				errorResponse = parse(string: ErrorResponse.errorToString(err), andLog: false)
			}
			
			errorResponse?.requestURL = requestURL
			errorResponse?.requestJSON = String(data: requestData ?? Data(), encoding: .utf8)
			errorResponse?.responseJSON = String(data: data ?? Data(), encoding: .utf8) ?? ""
			errorResponse?.httpStatusCode = httpResponse.statusCode
			errorResponse?.errorObject = networkError
			
		} else if let err = networkError {
			
			let requestJson = String(data: requestData ?? Data(), encoding: .utf8)
			let responseJson = String(data: data ?? Data(), encoding: .utf8)
			let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
			
			errorResponse = parse(string: ErrorResponse.errorToString(err), andLog: false)
			errorResponse?.requestURL = requestURL
			errorResponse?.requestJSON = requestJson
			errorResponse?.responseJSON = responseJson
			errorResponse?.httpStatusCode = statusCode
			errorResponse?.errorString = ErrorResponse.errorToString(err)
			errorResponse?.errorObject = err
		}
		
		// If we have any kind of error at this point, add in the network details
		if let errorRes = errorResponse {
			logAndCallback(withErrorResponse: errorRes)
		}
		
		return errorResponse
	}
	
	
	
	// MARK: - Error Extractors
	
	/**
	Process an array of `TzKTOperation` to determine if they contain a tezos error object
	- parameter tzktOperations: An array of operations returned from TzKT
	- returns `Bool`
	*/
	public class func containsErrors(tzktOperations: [TzKTOperation]) -> Bool {
		for op in tzktOperations {
			if op.containsError() {
				return true
			}
		}
		
		return false
	}
	
	/**
	There are 2 types of high level errors in Tezos.
	1. Account state errors: These errors are global across the entire ecosystem, and will effect any application, or product. Examples: insufficent balance, invalid address, invalid baker.
	2. Script errors: These errors are specific to each application. Examples: Dexter-invalid requested exchange operation, TNS-the requested domain name is unavailable.
	When working with smart contracts on Tezos, operations may have internal child operations, each of which can have an error. When an error of type 2 mentioned above,
	occurs the array of operations will contain many generic "a unknown script error occured" messages, with one of the operations containing the detailed, application specific error. This function is an
	attempt to abstract this logic away from developers, by simply taking in an array of operations, and returning the most meaningful error it can, to reduce time and effort.
	- Returns: `nil` if no errors found, useful for checking status, `.unknownError` if no meaningful errors can be found, or some `ErrorResponseType` matching the meaningful error
	*/
	public class func extractMeaningfulErrors(fromTzKTOperations operations: [TzKTOperation]) -> ErrorResponse? {
		
		// If operations contain no errors, return empty array
		guard operations.map({ $0.containsError() }).filter({ $0 == true }).count > 0 else {
			return nil
		}
		
		// Else, try to parse basic errors for something meaningful
		let errorArrays = operations.map({ $0.errors })
		var parsedErrors: [ErrorResponse] = []
		
		errorArrays.forEach { (array) in
			array?.forEach({ (error) in
				parsedErrors.append( ErrorHandlingService.parse(string: error.type, andLog: false) )
			})
		}
		
		let meaningfulErrors = parsedErrors.filter({ $0.errorType != .unknownError })
		
		// Only log the last error
		if meaningfulErrors.count != 0, let returningError = meaningfulErrors.last {
			logAndCallback(withErrorResponse: returningError)
			return returningError
		}
		
		return ErrorResponse.unknownError()
	}
	
	/**
	There are 2 types of high level errors in Tezos.
	1. Account state errors: These errors are global across the entire ecosystem, and will effect any application, or product. Examples: insufficent balance, invalid address, invalid baker.
	2. Script errors: These errors are specific to each application. Examples: Dexter-invalid requested exchange operation, TNS-the requested domain name is unavailable.
	When working with smart contracts on Tezos, operations may have internal child operations, each of which can have an error. When an error of type 2 mentioned above occurs,
	the array of operations will contain many generic "a unknown script error occured" messages, with one of the operations containing the detailed, application specific error. This function is an
	attempt to abstract this logic away from developers, by simply taking in an array of operations, and returning the most meaningful error it can, to reduce time and effort.
	- Returns: `nil` if no errors found, useful for checking status, `.unknownError` if no meaningful errors can be found, or some `ErrorResponseType` matching the meaningful error
	*/
	public class func extractMeaningfulErrors(fromRPCOperations operations: [OperationResponse], withRequestURL: URL?, requestPayload: Data?, responsePayload: Data?, httpStatusCode: Int?) -> ErrorResponse? {
		
		// If operations contain no errors, return empty array
		guard operations.map({ $0.errors().count > 0 }).filter({ $0 == true }).count > 0 else {
			return nil
		}
		
		// Else, try to parse basic errors for something meaningful
		let errorArrays = operations.map({ $0.errors() })
		var parsedErrors: [ErrorResponse] = []
		
		
		errorArrays.forEach { (array) in
			array.forEach({ (error) in
				
				// Error we are looking for could be inside the returned `.id` or optionally inside `.with.string`.
				// Since we are just just check for string contents, add both together and search the full string
				let fullErrorString = error.id + (error.with?.string ?? "")
				parsedErrors.append( ErrorHandlingService.parse(string: fullErrorString, andLog: false) )
			})
		}
		
		let meaningfulErrors = parsedErrors.filter({ $0.errorType != .unknownError })
		
		// Only log the last error
		if meaningfulErrors.count != 0 {
			var returningError = meaningfulErrors.last
			returningError?.requestURL = withRequestURL
			returningError?.requestJSON = String(data: requestPayload ?? Data(), encoding: .utf8)
			returningError?.responseJSON = String(data: responsePayload ?? Data(), encoding: .utf8)
			returningError?.httpStatusCode = httpStatusCode
			
			logAndCallback(withErrorResponse: returningError ?? ErrorResponse.unknownError())
			return returningError
		}
		
		return ErrorResponse.unknownError()
	}
	
	
	
	// MARK: - Logging
	
	private class func logAndCallback(withErrorResponse errorResponse: ErrorResponse) {
		os_log(.error, log: .kukaiCoreSwift, "Error parsed: %@", errorResponse.description)
		
		if let closure = ErrorHandlingService.shared.errorEventClosure {
			closure(errorResponse)
		}
	}
}

