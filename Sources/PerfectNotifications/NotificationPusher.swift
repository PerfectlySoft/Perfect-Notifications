//
//  NotificationPusher.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2016-02-16.
//  Copyright © 2016 PerfectlySoft. All rights reserved.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectLib
import PerfectNet
import PerfectThread
import PerfectHTTPServer
import PerfectHTTP
import PerfectCrypto
import Foundation

#if os(macOS)
	import Darwin
#else
	import SwiftGlibc
#endif

/// Items to configure an individual notification push.
public enum APNSNotificationItem {
    /// alert body child property
	case alertBody(String)
    /// alert title child property
	case alertTitle(String)
    /// alert title-loc-key
	case alertTitleLoc(String, [String]?)
    /// alert action-loc-key
	case alertActionLoc(String)
    /// alert loc-key
	case alertLoc(String, [String]?)
    /// alert launch-image
	case alertLaunchImage(String)
    /// aps badge key
	case badge(Int)
    /// aps sound key
	case sound(String)
    /// aps content-available key
	case contentAvailable
	/// aps category key
	case category(String)
	/// aps thread-id key
	case threadId(String)
    /// custom payload data
	case customPayload(String, Any)
    /// apn mutable-content key
    case mutableContent
}

/// Valid APNS priorities
public enum APNSPriority: Int {
	case immediate = 10
	case background = 5
}

/// Time in the future when the notification, if has not be able to be delivered, will expire.
public enum APNSExpiration {
	/// Discard the notification if it can't be immediately delivered.
	case immediate
	/// now + seconds
	case relative(Int)
	/// absolute UTC time since epoch
	case absolute(Int)
	
	var rawValue: Int {
		switch self {
		case .immediate: return 0
		case .relative(let v): return Int(time(nil)) + v
		case .absolute(let v): return v
		}
	}
	// TODO: deprecate
	init?(rawValue: Int) {
		self = .absolute(rawValue)
	}
}

public typealias APNSUUID = Foundation.UUID

typealias IOSNotificationItem = APNSNotificationItem

private let iosNotificationPort = UInt16(443)
private let iosNotificationDevelopmentHost = "api.development.push.apple.com"
private let iosNotificationProductionHost = "api.push.apple.com"

class NotificationConfiguration {
	let name: String
	let configurator: NotificationPusher.netConfigurator
	
	let keyId: String?
	let teamId: String?
	let privateKeyPath: String?
	let production: Bool
	var currentToken: String?
	var currentTokenTime = 0
	
	let lock = Threading.Lock()
	var streams = [NotificationHTTP2Client]()
	
	var usingJWT: Bool {
		return nil != keyId
	}
	
	var jwtToken: String? {
		let oneHour = 60 * 60
		let now = Int(time(nil))
		if now - currentTokenTime >= oneHour {
			guard let keyId = keyId, let teamId = teamId, let privateKeyPath = privateKeyPath else {
				return nil
			}
			currentTokenTime = now
			currentToken = makeSignature(keyId: keyId, teamId: teamId, privateKeyPath: privateKeyPath)
		}
		return currentToken
	}
	
	var notificationHostAPNS: String {
		// for compatability: if global debug was turned ON then respect it
		if NotificationPusher.development {
			return iosNotificationDevelopmentHost
		}
		if production {
			return iosNotificationProductionHost
		}
		return iosNotificationDevelopmentHost
	}
	
	init(name: String, configurator: @escaping NotificationPusher.netConfigurator, production: Bool) {
		self.name = name
		self.configurator = configurator
		keyId = nil
		teamId = nil
		self.production = production
		privateKeyPath = nil
	}
	
	init(name: String, keyId: String, teamId: String, privateKeyPath: String, production: Bool) {
		self.name = name
		configurator = { _ in }
		self.keyId = keyId
		self.teamId = teamId
		self.privateKeyPath = privateKeyPath
		self.production = production
	}
}

class NotificationHTTP2Client: HTTP2Client {
	let id: Int
    init(id: Int) {
        self.id = id
        super.init()
	}
}

/// The response object given after a push attempt.
public struct NotificationResponse: CustomStringConvertible {
	/// The response code for the request.
	public let status: HTTPResponseStatus
	/// The response body data bytes.
	public let body: [UInt8]
	/// The body data bytes interpreted as JSON and decoded into a Dictionary.
	public var jsonObjectBody: [String:Any] {
		do {
			if let json = try stringBody.jsonDecode() as? [String:Any] {
				return json
			}
		}
		catch {}
		return [String:Any]()
	}
	/// The body data bytes converted to String.
	public var stringBody: String {
		return UTF8Encoding.encode(bytes: self.body)
	}
	public var description: String {
		return "\(status): \(stringBody)"
	}
}

/// The interface for APNS notifications.
public class NotificationPusher {
	
	typealias ComponentGenerator = IndexingIterator<[String]>
	
	/// On-demand configuration for SSL related functions.
	public typealias netConfigurator = (NetTCPSSL) -> ()
	
	/// Toggle development or production on a global basis.
	// TODO: deprecate
	public static var development = false

	/// Sets the apns-topic which will be used for iOS notifications.
	public var apnsTopic: String
	public var expiration: APNSExpiration
	public var priority: APNSPriority
	public var collapseId: String?
	
	var responses = [NotificationResponse]()
	
	static var idCounter = 0
	
	static let configurationsLock = Threading.Lock()
	static var iosConfigurations = [String:NotificationConfiguration]()
	static var activeStreams = [Int:NotificationHTTP2Client]()
	
	/// Initialize given an apns-topic string.
	public init(apnsTopic: String,
	            expiration: APNSExpiration = .immediate,
	            priority: APNSPriority = .immediate,
	            collapseId: String? = nil) {
		self.apnsTopic = apnsTopic
		self.expiration = expiration
		self.priority = priority
		self.collapseId = collapseId
	}
	
	public static func addConfigurationAPNS(name: String, production: Bool, configurator: @escaping netConfigurator = { _ in }) {
		configurationsLock.doWithLock {
			self.iosConfigurations[name] = NotificationConfiguration(name: name, configurator: configurator, production: production)
		}
	}
	
	public static func addConfigurationAPNS(name: String, production: Bool, certificatePath: String) {
		addConfigurationIOS(name: name) {
			net in
			guard File(certificatePath).exists else {
				fatalError("File not found \(certificatePath)")
			}
			guard net.useCertificateFile(cert: certificatePath)
				&& net.usePrivateKeyFile(cert: certificatePath)
				&& net.checkPrivateKey() else {
					let code = Int32(net.errorCode())
					print("Error validating private key file: \(net.errorStr(forCode: code))")
					return
			}
		}
	}
	
	static func getConfiguration(name: String) -> NotificationConfiguration? {
		var conf: NotificationConfiguration?
		configurationsLock.doWithLock {
			conf = self.iosConfigurations[name]
		}
		return conf
	}
	
	static func getStreamAPNS(configuration c: NotificationConfiguration, callback: @escaping (HTTP2Client?, NotificationConfiguration?) -> ()) {
		var net: NotificationHTTP2Client?
		var needsConnect = false
		c.lock.doWithLock {
			if c.streams.count > 0 {
				net = c.streams.removeLast()
			} else {
				needsConnect = true
				net = NotificationHTTP2Client(id: idCounter)
				activeStreams[idCounter] = net
				idCounter = idCounter &+ 1
			}
		}
		if !needsConnect {
			// this is an existing, idle stream
			// send a ping to ensure it's valid
			// if it's not valid then open a new stream
			net?.sendPing {
				ok in
				guard ok else {
					return self.getStreamAPNS(configurationName: c.name, callback: callback)
				}
				callback(net, c)
			}
		} else {
			net?.net.initializedCallback = c.configurator
			net?.connect(host: c.notificationHostAPNS, port: iosNotificationPort, ssl: true, timeoutSeconds: 5.0) {
				b in
				if b {
					callback(net!, c)
				} else {
					callback(nil, nil)
				}
			}
		}
	}
	
	static func getStreamAPNS(configurationName configuration: String, callback: @escaping (HTTP2Client?, NotificationConfiguration?) -> ()) {
		guard let c = getConfiguration(name: configuration) else {
            return callback(nil, nil)
        }
		getStreamAPNS(configuration: c, callback: callback)
	}
	
	static func releaseStreamAPNS(configurationName configuration: String, net: HTTP2Client) {
		var conf: NotificationConfiguration?
		configurationsLock.doWithLock {
			conf = self.iosConfigurations[configuration]
		}
        guard let c = conf, let n = net as? NotificationHTTP2Client  else {
            net.close()
            return
        }
        c.lock.doWithLock {
            activeStreams.removeValue(forKey: n.id)
            if net.isConnected {
                c.streams.append(n)
            }
        }
	}

	func resetResponses() {
		responses.removeAll()
	}
	
	func pushAPNS(_ net: HTTP2Client, config: NotificationConfiguration, deviceToken: String, notificationJson: [UInt8], callback: @escaping (NotificationResponse) -> ()) {
		let request = net.createRequest()
		request.method = .post
		request.postBodyBytes = notificationJson
        request.setHeader(.contentType, value: "application/json; charset=utf-8")
        request.setHeader(.custom(name: "apns-expiration"), value: "\(expiration.rawValue)")
        request.setHeader(.custom(name: "apns-priority"), value: "\(priority.rawValue)")
		request.setHeader(.custom(name: "apns-topic"), value: apnsTopic)
		if let cid = collapseId {
			request.setHeader(.custom(name: "apns-collapse-id"), value: cid)
		}
		if config.usingJWT, let token = config.jwtToken {
			request.setHeader(.authorization, value: "bearer \(token)")
		}
		request.path = "/3/device/\(deviceToken)"
		net.sendRequest(request) {
			response, msg in
            guard let r = response else {
                return callback(NotificationResponse(status: .internalServerError, body: UTF8Encoding.decode(string: msg ?? "No response")))
            }
            callback(NotificationResponse(status: r.status, body: r.bodyBytes))
		}
	}
	
	func pushAPNS(_ client: HTTP2Client, config: NotificationConfiguration, deviceToken: String, remainingDeviceTokens: ComponentGenerator, notificationJson: [UInt8], callback: @escaping ([NotificationResponse]) -> ()) {
		pushAPNS(client, config: config, deviceToken: deviceToken, notificationJson: notificationJson) {
			response in
			if case .internalServerError = response.status {
				NotificationPusher.getStreamAPNS(configuration: config) {
					client, config in
					guard let client = client, let config = config else {
						let msg = "Connection could not be established"
						self.responses.append(NotificationResponse(status: .internalServerError, body: UTF8Encoding.decode(string: msg)))
						self.responses.append(contentsOf: remainingDeviceTokens.map { _ -> NotificationResponse in NotificationResponse(status: .internalServerError, body: UTF8Encoding.decode(string: msg)) })
						return callback(self.responses)
					}
					self.pushAPNS(client, config: config, deviceToken: deviceToken, remainingDeviceTokens: remainingDeviceTokens, notificationJson: notificationJson, callback: callback)
				}
			} else {
				self.responses.append(response)
				DispatchQueue.global().async {
					self.pushAPNS(client, config: config, deviceTokens: remainingDeviceTokens, notificationJson: notificationJson, callback: callback)
				}
			}
		}
	}
	
	func pushAPNS(_ client: HTTP2Client, config: NotificationConfiguration, deviceTokens: ComponentGenerator, notificationJson: [UInt8], callback: @escaping ([NotificationResponse]) -> ()) {
		var g = deviceTokens
        guard let next = g.next() else {
            return callback(responses)
        }
		pushAPNS(client, config: config, deviceToken: next, remainingDeviceTokens: g, notificationJson: notificationJson, callback: callback)
	}
	
	func pushAPNS(_ client: HTTP2Client, config: NotificationConfiguration, deviceTokens: [String], notificationItems: [APNSNotificationItem], callback: @escaping ([NotificationResponse]) -> ()) {
		resetResponses()
		let g = deviceTokens.makeIterator()
		let jsond = UTF8Encoding.decode(string: itemsToPayloadString(notificationItems: notificationItems))
		pushAPNS(client, config: config, deviceTokens: g, notificationJson: jsond, callback: callback)
	}
	
	func itemsToPayloadString(notificationItems items: [APNSNotificationItem]) -> String {
		var dict = [String:Any]()
		var aps = [String:Any]()
		var alert = [String:Any]()
		var alertBody: String?
		for item in items {
			switch item {
			case .alertBody(let s):
				alertBody = s
			case .alertTitle(let s):
				alert["title"] = s
			case .alertTitleLoc(let s, let a):
				alert["title-loc-key"] = s
				if let titleLocArgs = a {
					alert["title-loc-args"] = titleLocArgs
				}
			case .alertActionLoc(let s):
				alert["action-loc-key"] = s
			case .alertLoc(let s, let a):
				alert["loc-key"] = s
				if let locArgs = a {
					alert["loc-args"] = locArgs
				}
			case .alertLaunchImage(let s):
				alert["launch-image"] = s
			case .badge(let i):
				aps["badge"] = i
			case .sound(let s):
				aps["sound"] = s
			case .contentAvailable:
				aps["content-available"] = 1
			case .category(let s):
				aps["category"] = s
			case .threadId(let s):
				aps["thread-id"] = s
			case .customPayload(let s, let a):
				dict[s] = a
            case .mutableContent:
                aps["mutable-content"] = 1
            }
		}
		if let ab = alertBody {
			if alert.count == 0 { // just a string alert
				aps["alert"] = ab
			} else { // a dict alert
				alert["body"] = ab
				aps["alert"] = alert
			}
		}
		dict["aps"] = aps
		do {
			return try dict.jsonEncodedString()
		} catch {}
		return "{}"
	}
	
	// TODO: deprecate
	public convenience init() {
		self.init(apnsTopic: "")
	}
}

public extension NotificationPusher {
	/// Add an APNS configuration which can be later used to push notifications.
	public static func addConfigurationAPNS(name: String, production: Bool, keyId: String, teamId: String, privateKeyPath: String) {
		_ = PerfectCrypto.isInitialized
		guard File(privateKeyPath).exists else {
			fatalError("The private key file \"\(privateKeyPath)\" does not exist. Current working directory: \(Dir.workingDir.path)")
		}
		configurationsLock.doWithLock {
			self.iosConfigurations[name] = NotificationConfiguration(name: name, keyId: keyId, teamId: teamId, privateKeyPath: privateKeyPath, production: production)
		}
	}
}

public extension NotificationPusher {
	/// Push one message to one device.
	/// Provide the previously set configuration name, device token.
	/// Provide the expiration and priority as described here:
	///		https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/APNsProviderAPI.html
	/// Provide a list of APNSNotificationItems.
	/// Provide a callback with which to receive the response.
	public func pushAPNS(configurationName: String, deviceToken: String, notificationItems: [APNSNotificationItem], callback: @escaping (NotificationResponse) -> ()) {
		pushAPNS(configurationName: configurationName, deviceTokens: [deviceToken], notificationItems: notificationItems, callback: { lst in callback(lst.first!) })
	}
	
	/// Push one message to multiple devices.
	/// Provide the previously set configuration name, and zero or more device tokens. The same message will be sent to each device.
	/// Provide the expiration and priority as described here:
	///		https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/APNsProviderAPI.html
	/// Provide a list of APNSNotificationItems.
	/// Provide a callback with which to receive the responses.
	public func pushAPNS(configurationName: String, deviceTokens: [String],
	                     notificationItems: [APNSNotificationItem],
	                     callback: @escaping ([NotificationResponse]) -> ()) {
		
		NotificationPusher.getStreamAPNS(configurationName: configurationName) {
			client, config in
			guard let c = client, let config = config else {
				return callback([NotificationResponse(status: .internalServerError, body: [UInt8]())])
			}
			self.pushAPNS(c, config: config, deviceTokens: deviceTokens, notificationItems: notificationItems) {
				responses in
				NotificationPusher.releaseStreamAPNS(configurationName: configurationName, net: c)
				guard responses.count == deviceTokens.count else {
					return callback([NotificationResponse(status: .internalServerError, body: [UInt8]())])
				}
				callback(responses)
			}
		}
	}
}

public extension NotificationPusher {
	// TODO: deprecate
	public static func addConfigurationIOS(name: String, configurator: @escaping netConfigurator = { _ in }) {
		addConfigurationAPNS(name: name, production: NotificationPusher.development, configurator: configurator)
	}
	public static func addConfigurationIOS(name: String, certificatePath: String) {
		addConfigurationAPNS(name: name, production: NotificationPusher.development, certificatePath: certificatePath)
	}
	public static func addConfigurationIOS(name: String, keyId: String, teamId: String, privateKeyPath: String) {
		addConfigurationAPNS(name: name, production: NotificationPusher.development, keyId: keyId, teamId: teamId, privateKeyPath: privateKeyPath)
	}
	public func pushIOS(configurationName: String, deviceToken: String, expiration: UInt32, priority: UInt8, notificationItems: [APNSNotificationItem], callback: @escaping (NotificationResponse) -> ()) {
		pushIOS(configurationName: configurationName, deviceTokens: [deviceToken], expiration: expiration, priority: priority, notificationItems: notificationItems, callback: { lst in callback(lst.first!) })
	}
	public func pushIOS(configurationName: String, deviceTokens: [String], expiration: UInt32, priority: UInt8, notificationItems: [APNSNotificationItem], callback: @escaping ([NotificationResponse]) -> ()) {
		self.expiration = APNSExpiration(rawValue: Int(expiration)) ?? .immediate
		self.priority = APNSPriority(rawValue: Int(priority)) ?? .immediate
		pushAPNS(configurationName: configurationName, deviceTokens: deviceTokens, notificationItems: notificationItems, callback: callback)
	}
}

// !FIX! Downcasting to protocol does not work on Linux
// Not sure if this is intentional, or a bug.
func jsonEncodedStringWorkAround(_ o: Any) throws -> String {
    switch o {
    case let jsonAble as JSONConvertibleObject: // as part of Linux work around
        return try jsonAble.jsonEncodedString()
    case let jsonAble as JSONConvertible:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as String:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as Int:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as UInt:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as Double:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as Bool:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as [Any]:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as [[String:Any]]:
        return try jsonAble.jsonEncodedString()
    case let jsonAble as [String:Any]:
        return try jsonAble.jsonEncodedString()
    default:
        throw JSONConversionError.notConvertible(o)
    }
}

private func jsonSerialize(o: Any) -> String? {
	do {
		return try jsonEncodedStringWorkAround(o)
	} catch let e as JSONConversionError {
		print("Could not convert to JSON: \(e)")
	} catch {}
	return nil
}
