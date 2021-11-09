//
//  TezToolPrice.swift
//  
//
//  Created by Simon Mcloughlin on 04/11/2021.
//

import Foundation

public struct TezToolPriceResponse: Codable {
	
	// There are some tokens that are malformed, that contain no crtical data (eg. decimals). Using SwiftBySundells property wrapper to tell swift to simply ignore these
	@LossyCodableList var contracts: [TezToolPrice]
}

public struct TezToolPrice: Codable {
	
	public let symbol: String
	public let tokenAddress: String
	public let decimals: Int
	public let address: String
	public let ratio: Decimal
	public let currentPrice: Decimal
	public let buyPrice: XTZAmount
	public let pairs: [TezToolPair]
}

extension TezToolPrice: Hashable {
	
	/// Conforming to `Hashable` to enable working with UITableViewDiffableDataSource
	public func hash(into hasher: inout Hasher) {
		hasher.combine(tokenAddress)
		hasher.combine(buyPrice)
	}
}

extension TezToolPrice: Equatable {
	
	public static func == (lhs: TezToolPrice, rhs: TezToolPrice) -> Bool {
		return lhs.tokenAddress == rhs.tokenAddress
	}
}
