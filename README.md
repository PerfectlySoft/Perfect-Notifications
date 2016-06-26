# Perfect-Notifications
iOS Notifications for Perfect

Building
--------

Add this project as a dependency in your Package.swift file.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
.Package(url:"https://github.com/PerfectlySoft/Perfect-MongoDB.git", versions: Version(0,0,0)..<Version(10,0,0))
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Usage
--------

```swift
// BEGIN one-time initialization code

let configurationName = "My configuration name - can be whatever"

NotificationPusher.addConfigurationIOS(configurationName) {
    (net:NetTCPSSL) in

    // This code will be called whenever a new connection to the APNS service is required.
    // Configure the SSL related settings.

    net.keyFilePassword = "if you have password protected key file"

    guard net.useCertificateChainFile("path/to/entrust_2048_ca.cer") &&
        net.useCertificateFile("path/to/aps_development.pem") &&
        net.usePrivateKeyFile("path/to/key.pem") &&
        net.checkPrivateKey() else {

        let code = Int32(net.errorCode())
        print("Error validating private key file: \(net.errorStr(code))")
        return
    }
}

NotificationPusher.development = true // set to toggle to the APNS sandbox server

// END one-time initialization code

// BEGIN - individual notification push

let deviceId = "hex string device id"
let ary = [IOSNotificationItem.AlertBody("This is the message"), IOSNotificationItem.Sound("default")]
let n = NotificationPusher()

n.apnsTopic = "com.company.my-app"

n.pushIOS(configurationName, deviceToken: deviceId, expiration: 0, priority: 10, notificationItems: ary) {
    response in

    print("NotificationResponse: \(response.code) \(response.body)")
}

// END - individual notification push
```
