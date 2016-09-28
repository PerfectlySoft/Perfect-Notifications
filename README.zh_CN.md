# Perfect-Notifications [English](README.md)

<p align="center">
    <a href="http://perfect.org/get-involved.html" target="_blank">
        <img src="http://perfect.org/assets/github/perfect_github_2_0_0.jpg" alt="Get Involed with Perfect!" width="854" />
    </a>
</p>

<p align="center">
    <a href="https://github.com/PerfectlySoft/Perfect" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_1_Star.jpg" alt="Star Perfect On Github" />
    </a>  
    <a href="https://gitter.im/PerfectlySoft/Perfect" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_2_Git.jpg" alt="Chat on Gitter" />
    </a>  
    <a href="https://twitter.com/perfectlysoft" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_3_twit.jpg" alt="Follow Perfect on Twitter" />
    </a>  
    <a href="http://perfect.ly" target="_blank">
        <img src="http://www.perfect.org/github/Perfect_GH_button_4_slack.jpg" alt="Join the Perfect Slack" />
    </a>
</p>

<p align="center">
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Swift-3.0-orange.svg?style=flat" alt="Swift 3.0">
    </a>
    <a href="https://developer.apple.com/swift/" target="_blank">
        <img src="https://img.shields.io/badge/Platforms-OS%20X%20%7C%20Linux%20-lightgray.svg?style=flat" alt="Platforms OS X | Linux">
    </a>
    <a href="http://perfect.org/licensing.html" target="_blank">
        <img src="https://img.shields.io/badge/License-Apache-lightgrey.svg?style=flat" alt="License Apache">
    </a>
    <a href="http://twitter.com/PerfectlySoft" target="_blank">
        <img src="https://img.shields.io/badge/Twitter-@PerfectlySoft-blue.svg?style=flat" alt="PerfectlySoft Twitter">
    </a>
    <a href="https://gitter.im/PerfectlySoft/Perfect?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge" target="_blank">
        <img src="https://img.shields.io/badge/Gitter-Join%20Chat-brightgreen.svg" alt="Join the chat at https://gitter.im/PerfectlySoft/Perfect">
    </a>
    <a href="http://perfect.ly" target="_blank">
        <img src="http://perfect.ly/badge.svg" alt="Slack Status">
    </a>
</p>

Notifications for Perfect 之 iOS消息推送


## 问题清单

我们目前正在过渡到使用JIRA来处理所有源代码资源合并申请、修复漏洞以及其它有关问题。因此，GitHub 的“issues”问题报告功能已经被禁用了。

如果您发现了问题，或者希望为改进本文提供意见和建议，[请在这里指出](http://jira.perfect.org:8080/servicedesk/customer/portal/1).

在您开始之前，请参阅[目前待解决的问题清单](http://jira.perfect.org:8080/projects/ISS/issues).


编译
--------

请在您的Perfect项目中的Package.swift文件增加以下依存关系：

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
.Package(url:"https://github.com/PerfectlySoft/Perfect-Notifications.git", majorVersion: 2, minor: 0)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

使用方法
--------

```swift
// 初始化开始，只需要运行一次即可
// 配置文件名称，请根据实际需要具体调整
let configurationName = "My configuration name - can be whatever"

NotificationPusher.addConfigurationIOS(configurationName) {
    (net:NetTCPSSL) in

    // 以下代码只要有APNS服务连接时都会被调用。
    // 配置SSL相关设置。

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

NotificationPusher.development = true // 打开APNS沙箱服务器开关

// 初始化结束

// 以下内容是消息推送实例：
// deviceId 是一个16进制设备编码
let deviceId = "hex string device id"
let ary = [IOSNotificationItem.AlertBody("在这里发送消息"), IOSNotificationItem.Sound("default")]
let n = NotificationPusher()

n.apnsTopic = "com.company.my-app"

n.pushIOS(configurationName, deviceToken: deviceId, expiration: 0, priority: 10, notificationItems: ary) {
    response in

    print("消息推送返回结果\(response.code) \(response.body)")
}

// 消息推送完成
```



## 更多内容
更多内容请参考Perfect项目[perfect.org](http://perfect.org).
