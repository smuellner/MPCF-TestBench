//
//  MPCFTestRunnerModel.swift
//  MPCF-Reflector
//
//  Created by Joseph Heck on 4/30/20.
//  Copyright © 2020 JFH Consulting. All rights reserved.
//

import Foundation
import MultipeerConnectivity
import OpenTelemetryModels

/// Handles the automatic reactions to Multipeer traffic - accepting invitations and responding to any data sent.
class MPCFTestRunnerModel: NSObject, ObservableObject, MPCFProxyResponder {
    internal var currentAdvertSpan: OpenTelemetry.Span?
    internal var session: MCSession?

    private var spanCollector: OTSimpleSpanCollector
    private var sessionSpans: [MCPeerID: OpenTelemetry.Span] = [:]

    // local temp collection to track spans between starting and finishing recv resource
    private var dataSpans: [MCPeerID: OpenTelemetry.Span] = [:]

    // local lookup that matches spans with explicit transmissions to a reflector
    private var transmissionSpans: [TransmissionIdentifier: OpenTelemetry.Span] = [:]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Initializers

    init(spanCollector: OTSimpleSpanCollector) {
        self.spanCollector = spanCollector
    }

    // MARK: State based intializers & SwiftUI exported data views

    @Published var targetPeer: MCPeerID?
    @Published var numberOfTransmissionsToSend: Int = 0 {  // 1, 10, 100
        didSet {
            // compare to the count we have - if we need more
            if numberOfTransmissionsToSend < xmitLedger.count {
                // initialize the data, send it, and record it
                // in our manifest against future responses
                for _ in 0...(xmitLedger.count - numberOfTransmissionsToSend) {
                    sendAndRecordTransmission()
                }
            }
        }
    }
    @Published var numberOfTransmissionsRecvd: Int = 0

    // collection of information about data transmissions
    // Bool? gives you a tri-state, nil, true, and false
    // nil == error on send
    // true/false == transmission has been sent, if we received a response
    private var xmitLedger: [TransmissionIdentifier: Bool?] = [:]
    @Published var transmissionsSent: [TransmissionIdentifier] = []

    private func sendAndRecordTransmission() {
        guard let targetPeer = targetPeer, let session = session else {
            // do nothing to send data if there's no target identified
            // or not session defined
            return
        }
        let xmitId = TransmissionIdentifier(traceName: "xmit")
        let envelope = ReflectorEnvelope(id: xmitId, size: .x1k)
        var xmitSpan: OpenTelemetry.Span?
        do {

            xmitSpan = sessionSpans[targetPeer]?.createChildSpan(name: "data xmit")

            // encode, and wrap it in a span
            var encodespan = xmitSpan?.createChildSpan(name: "encode")
            let rawdata = try encoder.encode(envelope)
            encodespan?.finish()
            spanCollector.collectSpan(encodespan)

            // send, and wrap it in a span
            var sessionSendSpan = xmitSpan?.createChildSpan(name: "session.send")
            try session.send(rawdata, toPeers: [targetPeer], with: .reliable)
            sessionSendSpan?.finish()
            spanCollector.collectSpan(sessionSendSpan)

            // record that we sent it, and the span to close it later...
            transmissionSpans[xmitId] = xmitSpan
            xmitLedger[xmitId] = false
            transmissionsSent.append(xmitId)
        } catch {
            // TODO: perhaps share notifications of any errors on sending..
            print("Error attempting to encode and send data: ", error)
            xmitLedger[xmitId] = nil
        }
    }

    // MARK: MCNearbyServiceAdvertiserDelegate

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // we received an invitation - which we can respond with an MCSession and affirmation to join

        print("received invitation from ", peerID)
        if var currentAdvertSpan = currentAdvertSpan {
            // if we have an avertising span, let's append some events related to the browser on it.
            currentAdvertSpan.addEvent(
                OpenTelemetry.Event(
                    "didReceiveInvitationFromPeer",
                    attr: [OpenTelemetry.Attribute("peerID", peerID.displayName)]))
        }
        // DECLINE all invitations with the default session that we built - this mechanism is
        // set up to only initiate requests and sessions.
        invitationHandler(false, nil)

    }

    // MARK: MCSessionDelegate methods

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {

        switch state {
        case MCSessionState.connected:
            print("Connected: \(peerID.displayName)")
            // event in the session span?
            if var sessionSpan = sessionSpans[peerID] {
                sessionSpan.addEvent(
                    OpenTelemetry.Event(
                        "sessionConnected",
                        attr: [OpenTelemetry.Attribute("peerID", peerID.displayName)]))
                // not sure if this is needed - I think we may have made a local copy here...
                // so this updates the local collection of spans with our updated version
                sessionSpans[peerID] = sessionSpan
            }

        case MCSessionState.connecting:
            print("Connecting: \(peerID.displayName)")
            // i think this is the start of the span - but it might be when we recv invitation above...
            if let currentAdvertSpan = currentAdvertSpan {
                var sessionSpan = currentAdvertSpan.createChildSpan(name: "MPCFsession")
                // add an attribute of the current peer
                sessionSpan.setTag("peerID", peerID.displayName)
                // add it into our collection, referenced by Peer
                sessionSpans[peerID] = sessionSpan
            }

        case MCSessionState.notConnected:
            print("Not Connected: \(peerID.displayName)")
            // and this is the end of a span... I think
            if var sessionSpan = sessionSpans[peerID] {
                sessionSpan.finish()
                spanCollector.collectSpan(sessionSpan)
            }
            // after we "record" it - we kill the current span reference in the dictionary by peer
            sessionSpans.removeValue(forKey: peerID)

        @unknown default:
            fatalError("unsupported MCSessionState result")
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // when we're receiving data, it's generally because we've had it reflected back to
        // us from a corresponding reflector. This is the point at which we can mark a signal
        // as complete from having been sent "there and back".
        do {
            let foo = try decoder.decode(ReflectorEnvelope.self, from: data)
            let xmitId = foo.id
            xmitLedger[xmitId] = true
            if var xmitSpan = transmissionSpans[xmitId] {
                xmitSpan.finish()
                spanCollector.collectSpan(xmitSpan)
            }
        } catch {
            print("Error while working with received data: ", error)
        }

    }

    func session(
        _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {

        // DO NOTHING - no stream receipt support
    }

    func session(
        _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, with progress: Progress
    ) {

        print("starting receiving resource: \(resourceName)")
        // event in the session span?
        if let sessionSpan = sessionSpans[peerID] {
            var recvDataSpan = sessionSpan.createChildSpan(name: "MPCF-recv-resource")
            // add an attribute of the current peer
            recvDataSpan.setTag("peerID", peerID.displayName)
            // add it into our collection, referenced by Peer
            dataSpans[peerID] = recvDataSpan
        }
    }

    func session(
        _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {

        // localURL is a temporarily file with the resource in it
        print("finished receiving resource: \(resourceName)")

        if var recvDataSpan = dataSpans[peerID] {
            // complete the span
            recvDataSpan.finish()
            // send it on the collector
            spanCollector.collectSpan(recvDataSpan)
            // clear it from our temp collection
            dataSpans[peerID] = nil
        }

    }

}