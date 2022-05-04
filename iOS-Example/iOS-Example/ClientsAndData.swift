//
//  ClientsAndData.swift
//  iOS-Example
//
//  Created by Simon Mcloughlin on 10/06/2021.
//  Copyright © 2021 Kukai AB. All rights reserved.
//

import Foundation
import KukaiCoreSwift

public class ClientsAndData {
	
	public static let shared = ClientsAndData()
	
	// Clients
	var clientConfig: TezosNodeClientConfig
	var tezosNodeClient: TezosNodeClient
	var bcdClient: BetterCallDevClient
	var tzktClient: TzKTClient
	var tezosDomainsClient: TezosDomainsClient
	var torusAuthService: TorusAuthService
	var dipDupClient: DipDupClient
	
	
	// Data
	var currentWalletAddress = ""
	var account: Account? = nil
	
	
	private init() {
		clientConfig = TezosNodeClientConfig(withDefaultsForNetworkType: .mainnet)
		tezosNodeClient = TezosNodeClient(config: clientConfig)
		bcdClient = BetterCallDevClient(networkService: tezosNodeClient.networkService, config: clientConfig)
		tzktClient = TzKTClient(networkService: tezosNodeClient.networkService, config: clientConfig, betterCallDevClient: bcdClient)
		tezosDomainsClient = TezosDomainsClient(networkService: tezosNodeClient.networkService, config: clientConfig)
		torusAuthService = TorusAuthService(networkService: tezosNodeClient.networkService, verifiers: [:])
		dipDupClient = DipDupClient(networkService: tezosNodeClient.networkService, config: clientConfig)
	}
	
	public func updateNetwork(network: TezosNodeClientConfig.NetworkType) {
		clientConfig = TezosNodeClientConfig(withDefaultsForNetworkType: network)
		tezosNodeClient = TezosNodeClient(config: clientConfig)
		bcdClient = BetterCallDevClient(networkService: tezosNodeClient.networkService, config: clientConfig)
		tzktClient = TzKTClient(networkService: tezosNodeClient.networkService, config: clientConfig, betterCallDevClient: bcdClient)
		tezosDomainsClient = TezosDomainsClient(networkService: tezosNodeClient.networkService, config: clientConfig)
		torusAuthService = TorusAuthService(networkService: tezosNodeClient.networkService, verifiers: [:])
		dipDupClient = DipDupClient(networkService: tezosNodeClient.networkService, config: clientConfig)
	}
}
