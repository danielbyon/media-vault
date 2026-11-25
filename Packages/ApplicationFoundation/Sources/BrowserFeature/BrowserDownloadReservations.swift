//
//  BrowserDownloadReservations.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Reserves each native writer's full allowance before WebKit can create a destination.
/// Cancellation keeps its charge until termination, including bytes beyond the item limit.
struct BrowserDownloadReservations {
    static let itemLimit: Int64 = 536_870_912
    private static let stagingLimit: Int64 = 2_147_483_648
    private static let freeSpaceFloor: Int64 = 536_870_912

    private struct Reservation {
        var received: Int64 = 0
        var charge: Int64 = BrowserDownloadReservations.itemLimit
    }

    private var reservations: [UUID: Reservation] = [:]

    mutating func reserve(
        _ id: UUID,
        availableBytes: Int64?,
        acceptedPendingBytes: Int64?,
        requestedBytes: Int64 = itemLimit,
    ) -> Bool {
        guard reservations[id] == nil,
              requestedBytes >= 0, requestedBytes <= Self.itemLimit,
              let availableBytes, let acceptedPendingBytes,
              availableBytes >= Self.freeSpaceFloor,
              acceptedPendingBytes >= 0, acceptedPendingBytes <= Self.stagingLimit
        else {
            return false
        }

        let charged = reservations.values.reduce(Int64(0)) { $0 + $1.charge }
        let unwritten = reservations.values.reduce(Int64(0)) { $0 + max(0, $1.charge - $1.received) }
        guard charged <= Self.stagingLimit - acceptedPendingBytes,
              requestedBytes <= Self.stagingLimit - acceptedPendingBytes - charged,
              unwritten <= availableBytes - Self.freeSpaceFloor,
              requestedBytes <= availableBytes - Self.freeSpaceFloor - unwritten
        else {
            return false
        }

        reservations[id] = Reservation(charge: requestedBytes)
        return true
    }

    /// Progress cannot reduce a reservation. An oversized writer must be cancelled by its owner.
    mutating func observe(_ id: UUID, receivedBytes: Int64) -> Bool {
        guard var reservation = reservations[id] else {
            return false
        }

        reservation.received = max(reservation.received, max(0, receivedBytes))
        // A charge above the aggregate ceiling already blocks admission. Saturation keeps
        // untrusted progress values from overflowing the sum of concurrent reservations.
        reservation.charge = min(Self.stagingLimit + 1, max(reservation.charge, reservation.received))
        reservations[id] = reservation
        return reservation.received <= Self.itemLimit
    }

    mutating func release(_ id: UUID) {
        reservations.removeValue(forKey: id)
    }

    /// Only a stopped, verified writer can release its unused byte allowance.
    mutating func completed(_ id: UUID, byteCount: Int64) {
        guard byteCount >= 0, byteCount <= Self.itemLimit, reservations[id] != nil else {
            return
        }

        reservations[id] = Reservation(received: byteCount, charge: byteCount)
    }
}
