//
//  BrowserDownloadReservationTests.swift
//  MediaVault
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import BrowserFeature

struct BrowserDownloadReservationTests {
    @Test
    func knownPresentationBytesReserveOnlyTheirBoundedCopyAllowance() {
        var budget = BrowserDownloadReservations()
        let export = UUID()
        let admitted = budget.reserve(
            export,
            availableBytes: 536_870_914,
            acceptedPendingBytes: 0,
            requestedBytes: 2,
        )
        #expect(admitted)
        let denied = budget.reserve(UUID(), availableBytes: 536_870_914, acceptedPendingBytes: 0, requestedBytes: 1)
        #expect(!denied)
        budget.completed(export, byteCount: 2)
        let next = budget.reserve(UUID(), availableBytes: 536_870_914, acceptedPendingBytes: 0, requestedBytes: 2)
        #expect(next)
    }

    @Test
    func unknownWritersReserveTheirFullItemLimit() {
        var budget = BrowserDownloadReservations()
        let ids = (0 ..< 5).map { _ in UUID() }
        for id in ids.prefix(4) {
            let result1 = budget.reserve(id, availableBytes: 3_221_225_472, acceptedPendingBytes: 0)
            #expect(result1)
        }
        let result2 = !budget.reserve(ids[4], availableBytes: 3_221_225_472, acceptedPendingBytes: 0)
        #expect(result2)
        budget.release(ids[0])
        let result3 = budget.reserve(ids[4], availableBytes: 3_221_225_472, acceptedPendingBytes: 0)
        #expect(result3)
    }

    @Test
    func freeSpaceFloorIncludesConcurrentUnwrittenReservations() {
        var budget = BrowserDownloadReservations()
        let first = UUID()
        let result4 = budget.reserve(first, availableBytes: 1_073_741_824, acceptedPendingBytes: 0)
        #expect(result4)
        let result5 = !budget.reserve(UUID(), availableBytes: 1_073_741_824, acceptedPendingBytes: 0)
        #expect(result5)
        let result6 = budget.observe(first, receivedBytes: 536_870_912)
        #expect(result6)
        let result7 = budget.reserve(UUID(), availableBytes: 1_073_741_824, acceptedPendingBytes: 0)
        #expect(result7)
    }

    @Test
    func acceptedPendingBytesReduceAggregateAdmissionCapacity() {
        var budget = BrowserDownloadReservations()
        let result8 = budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: 1_610_612_736)
        #expect(result8)
        let result9 = !budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: 1_610_612_736)
        #expect(result9)
    }

    @Test
    func cancellationOvershootRemainsChargedUntilWriterTermination() {
        var budget = BrowserDownloadReservations()
        let id = UUID()
        let result10 = budget.reserve(id, availableBytes: 4_294_967_296, acceptedPendingBytes: 0)
        #expect(result10)
        let result11 = !budget.observe(id, receivedBytes: 536_870_913)
        #expect(result11)
        let result12 = !budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: 1_073_741_824)
        #expect(result12)
        budget.release(id)
        let result13 = budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: 1_073_741_824)
        #expect(result13)
    }

    @Test
    func completedWritersReleaseUnusedAllowanceWithoutLosingTheirBytes() {
        var budget = BrowserDownloadReservations()
        let id = UUID()
        let admitted = budget.reserve(id, availableBytes: 4_294_967_296, acceptedPendingBytes: 1_610_612_736)
        #expect(admitted)
        budget.completed(id, byteCount: 2)
        let oversized = budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: 1_610_612_736)
        #expect(!oversized)
        budget.release(id)
        let released = budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: 1_610_612_736)
        #expect(released)
    }

    @Test
    func extremeCancellationProgressCannotOverflowAccounting() {
        var budget = BrowserDownloadReservations()
        let first = UUID()
        let second = UUID()
        _ = budget.reserve(first, availableBytes: 4_294_967_296, acceptedPendingBytes: 0)
        _ = budget.reserve(second, availableBytes: 4_294_967_296, acceptedPendingBytes: 0)
        let withinLimit = budget.observe(first, receivedBytes: Int64.max)
        #expect(!withinLimit)
        let admitted = budget.reserve(UUID(), availableBytes: Int64.max, acceptedPendingBytes: 0)
        #expect(!admitted)
    }

    @Test
    func unavailableOrNegativeAccountingFailsClosed() {
        var budget = BrowserDownloadReservations()
        let result14 = !budget.reserve(UUID(), availableBytes: nil, acceptedPendingBytes: 0)
        #expect(result14)
        let result15 = !budget.reserve(UUID(), availableBytes: 4_294_967_296, acceptedPendingBytes: nil)
        #expect(result15)
        let result16 = !budget.reserve(UUID(), availableBytes: -1, acceptedPendingBytes: 0)
        #expect(result16)
        let result17 = !budget.reserve(UUID(), availableBytes: Int64.max, acceptedPendingBytes: Int64.max)
        #expect(result17)
    }
}
