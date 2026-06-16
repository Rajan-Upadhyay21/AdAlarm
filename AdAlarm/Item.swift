//
//  Item.swift
//  AdAlarm
//
//  Created by Rajan Upadhyay on 6/15/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
