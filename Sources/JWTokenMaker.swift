//
//  JWTokenMaker.swift
//  Perfect-NotificationsExample
//
//  Created by Kyle Jessup on 2017-02-02.
//	Copyright (C) 2017 PerfectlySoft, Inc.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2017 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

import PerfectCrypto
import PerfectLib

#if os(macOS)
import Darwin
#else
import SwiftGlibc
#endif

let jwtSigAlgo = JWT.Alg.es256

func makeSignature(keyId: String, teamId: String, privateKeyPath: String) -> String? {
	let extraHead = ["kid":keyId]
	let payload: [String:Any] = ["iss":teamId, "iat":Int(time(nil))]
	
	guard let jwt = JWTCreator(payload: payload) else {
		return nil
	}
	do {
		let pem = try PEMKey(pemPath: privateKeyPath)
		let sig = try jwt.sign(alg: jwtSigAlgo, key: pem, headers: extraHead)
		return sig
	} catch {
		return nil
	}
}



