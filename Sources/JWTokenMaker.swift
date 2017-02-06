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

import PerfectLib
#if os(macOS)
import Darwin
#else
import SwiftGlibc
#endif

import COpenSSL

let jwtSigAlgo = "ES256"

func encodeBase64URL(_ buffer: UnsafeRawBufferPointer) -> String? {
	guard let r = buffer.base64, let f = r.characters.split(separator: "=").first else {
		return nil
	}
	return String(f.map { $0 == "+" ? "-" : ($0 == "/" ? "_" : $0) })
}

func encodeBase64URL(_ j: JSONConvertible) throws -> String? {
	let c = try j.jsonEncodedString().utf8
	let ca = [UInt8](c)
	return encodeBase64URL(UnsafeRawBufferPointer(start: UnsafePointer(ca), count: ca.count))
}

func getPrivKey(_ privateKeyPath: String) -> BIGNUM? {
	var keyPtr = EVP_PKEY_new()
	defer {
		EVP_PKEY_free(keyPtr)
	}
	let fp = fopen(privateKeyPath, "r")
	PEM_read_PrivateKey(fp, &keyPtr, nil, nil) // nil pw callback
	fclose(fp)
	guard let ecKey = EVP_PKEY_get1_EC_KEY(keyPtr) else {
		return nil
	}
	EC_KEY_set_conv_form(ecKey, POINT_CONVERSION_UNCOMPRESSED)
	guard let bn = EC_KEY_get0_private_key(ecKey) else {
		return nil
	}
	var retBn = BIGNUM()
	BN_init(&retBn)
	BN_copy(&retBn, bn)
	return retBn
}

func signMessage(_ message: UnsafeRawBufferPointer, privKey: BIGNUM) -> UnsafeMutableRawBufferPointer? {
	guard let ecKey = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1) else {
		return nil
	}
	var privKey = privKey
	EC_KEY_set_private_key(ecKey, &privKey)
	let bnCtx = BN_CTX_new()
	BN_CTX_start(bnCtx)
	let grp = EC_KEY_get0_group(ecKey)
	let pubK = EC_POINT_new(grp)
	EC_POINT_mul(grp, pubK, &privKey, nil, nil, bnCtx)
	EC_KEY_set_public_key(ecKey, pubK)
	EC_POINT_free(pubK)
	BN_CTX_end(bnCtx)
	BN_CTX_free(bnCtx)
	
	guard let sig = ECDSA_do_sign(message.baseAddress?.assumingMemoryBound(to: UInt8.self), Int32(message.count), ecKey) else {
		return nil
	}
	let derLen = ECDSA_size(ecKey)
	let derEncoded = UnsafeMutableRawBufferPointer.allocate(count: Int(derLen))
	var derByts = derEncoded.baseAddress?.assumingMemoryBound(to: UInt8.self)
	i2d_ECDSA_SIG(sig, &derByts)
	return derEncoded
}

func makeSignature(keyId: String, teamId: String, privateKeyPath: String) -> String? {
	do {
		guard let h1 = try encodeBase64URL(["typ":"JWT", "alg":jwtSigAlgo, "kid":keyId]),
			let h2 = try encodeBase64URL(["iss":teamId, "iat":Int(time(nil))]),
			var privKey = getPrivKey(privateKeyPath) else {
				return nil
		}
		defer {
			BN_clear_free(&privKey)
		}
		let frst = h1 + "." + h2
		let ca = [UInt8](frst.utf8)
		let capsha = UnsafeRawBufferPointer(start: UnsafePointer(ca), count: ca.count).sha256
		defer {
			capsha.deallocate()
		}
		guard let signed = signMessage(UnsafeRawBufferPointer(capsha), privKey: privKey) else {
			return nil
		}
		defer {
			signed.deallocate()
		}
		guard let lastEnc = encodeBase64URL(UnsafeRawBufferPointer(signed)) else {
			return nil
		}
		return frst + "." + lastEnc
	} catch {
		return nil
	}	
}

extension UnsafeRawBufferPointer {
	var base64: String? {
		var bufferPtr = UnsafeMutablePointer<BUF_MEM>(bitPattern: 0)
		let b64 = BIO_new(BIO_f_base64())
		let bio = BIO_push(b64, BIO_new(BIO_s_mem()))
		BIO_set_flags(bio, BIO_FLAGS_BASE64_NO_NL)
		BIO_write(bio, self.baseAddress, Int32(self.count))
		BIO_ctrl(bio, BIO_CTRL_FLUSH, 0, nil)
		BIO_ctrl(bio, BIO_C_GET_BUF_MEM_PTR, 0, &bufferPtr)
		defer {
			BIO_free_all(bio)
		}
		guard let buffer = bufferPtr, let outData = buffer.pointee.data else {
			return nil
		}
		let length = buffer.pointee.length
		let gen = GenerateFromPointer(from: outData.withMemoryRebound(to: UInt8.self, capacity: length) { return $0 }, count: length)
		let ret = UTF8Encoding.encode(generator: gen)
		return ret
	}
	
	// return value should be deallocated by caller
	var sha256: UnsafeMutableRawBufferPointer {
		var c = SHA256_CTX()
		let ret = UnsafeMutableRawBufferPointer.allocate(count: Int(SHA256_DIGEST_LENGTH))
		SHA256_Init(&c)
		SHA256_Update(&c, self.baseAddress, self.count)
		SHA256_Final(ret.baseAddress?.assumingMemoryBound(to: UInt8.self), &c)
		OPENSSL_cleanse(&c, MemoryLayout<SHA256_CTX>.size)
		return ret
	}
}


