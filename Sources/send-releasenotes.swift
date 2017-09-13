//
//  send-releasenotes.swift
//  CI-Utils
//
//  Created by Kyle Watson on 9/11/17.
//
//

import Foundation
import Moderator
import JiraKit
import SwiftSendmail
import SwiftLogger
import SwiftHTML
import SwiftShell
import Unbox

extension Sequence {
    func group<GroupingType: Hashable>(by key: (Iterator.Element) -> GroupingType) -> [GroupingType: [Iterator.Element]] {
        var groups: [GroupingType: [Iterator.Element]] = [:]
        forEach { element in
            let key = key(element)
            if case nil = groups[key]?.append(element) {
                groups[key] = [element]
            }
        }
        return groups
    }
}

struct IssueType {
    let name: String
    let imageHref: String
}

extension IssueType: Unboxable {
    init(unboxer: Unboxer) throws {
        self.name = try unboxer.unbox(key: "name")
        self.imageHref = try unboxer.unbox(key: "iconUrl")
    }
}

struct IssueReporter {
    let name: String
    let imageHref: String
}

extension IssueReporter: Unboxable {
    init(unboxer: Unboxer) throws {
        self.name = try unboxer.unbox(key: "displayName")
        self.imageHref = try unboxer.unbox(keyPath: "avatarUrls.16x16")
    }
}

struct IssueAssignee {
    let name: String
    let imageHref: String
}

extension IssueAssignee: Unboxable {
    init(unboxer: Unboxer) throws {
        self.name = try unboxer.unbox(key: "displayName")
        self.imageHref = try unboxer.unbox(keyPath: "avatarUrls.16x16")
    }
}

struct IssuePriority {
    let name: String
    let imageHref: String
}

extension IssuePriority: Unboxable {
    init(unboxer: Unboxer) throws {
        self.name = try unboxer.unbox(key: "name")
        self.imageHref = try unboxer.unbox(key: "iconUrl")
    }
}

struct Issue {
    let key: String
    let summary: String
    let fixVersion: String
    let updated: String
    let type: IssueType
    let reporter: IssueReporter
    let assignee: IssueAssignee?
    let priority: IssuePriority
}

extension Issue: Unboxable {
    init(unboxer: Unboxer) throws {
        self.key = try unboxer.unbox(key: "key")
        self.summary = try unboxer.unbox(keyPath: "fields.summary")
        self.fixVersion = try unboxer.unbox(keyPath: "fields.fixVersions.0.name")
        self.updated = try unboxer.unbox(keyPath: "fields.updated")
        self.type = try unboxer.unbox(keyPath: "fields.issuetype")
        self.reporter = try unboxer.unbox(keyPath: "fields.reporter")
        self.assignee = unboxer.unbox(keyPath: "fields.assignee")
        self.priority = try unboxer.unbox(keyPath: "fields.priority")
    }
}

struct HTMLReport: SwiftHTML, CustomStringConvertible {
    typealias IssueGroups = [String: [Issue]]
    
    let version: String
    let build: String
    let issueGroups: IssueGroups
    
    var description: String {
        return String(describing: HTML(
            head([
                node("style", ["type" => "text/css"], ["\n* {font-family: sans-serif;}\n ul {list-style: none;}\n li {margin: 1em 0;}\n img {vertical-align: top; width: 16px; height: 16px}\n"])
            ]),
            body([
                h1(.text("tvOS \(version) (\(build)) Dev Complete Tickets")),
                div([strong("Note: "), "This build is processing and should be available shortly"])
            ] + nodes))
        )
    }
    
    private var nodes: [Node] {
        return issueGroups.flatMap { (type, issues) -> Node in
            return div([
                h2(.text(type)),
                ul(issues.flatMap({ (issue) -> Node in
                    return li([
                        div([strong("Ticket: "), a([href => "http://tickets.turner.com/browse/\(issue.key)"], .text(issue.key)), " - ", .text(issue.summary)]),
                        div([strong("Priority: "), img([src => issue.priority.imageHref]), .text(issue.priority.name)]),
                        div([strong("Fix Version: "), .text(issue.fixVersion)]),
                        div([strong("Reported By: "), img([src => issue.reporter.imageHref]), .text(issue.reporter.name)]),
                        issue.assignee != nil ? div([strong("Assigned To: "), img([src => issue.assignee!.imageHref]), .text(issue.assignee!.name)]) : div([]),
                        div([strong("Updated: "), .text(issue.updated)])
                    ])
                }))
            ])
        }
    }
    
    init(version: String, build: String, issueGroups: IssueGroups) {
        self.version = version
        self.build = build
        self.issueGroups = issueGroups
    }
}

// specify args
let arguments = Moderator(description: "Search JIRA and send release notes to specified recipients")

let host = arguments.add(Argument<String>
    .optionWithValue("h", name: "host", description: "The host to Jira")
    .required()
)
let jql = arguments.add(Argument<String>
    .optionWithValue("j", name: "jql", description: "Jira JQL query")
    .required()
)
let version = arguments.add(Argument<String>
    .optionWithValue("v", name: "version", description: "Build version")
    .required()
)
let build = arguments.add(Argument<String>
    .optionWithValue("b", name: "build", description: "Build number")
    .required()
)
let pathToRecipients = arguments.add(Argument<String>
    .optionWithValue("r", name: "recipients", description: "Path to recipients file")
    .required()
)

// parse args
do {
    try arguments.parse()
} catch {
    Logger.error("Unable to parse args:", error)
    exit(Int32(error._code))
}

// parse recipients from file
let recipients = { () -> [String] in
    do {
        return try open(pathToRecipients.value)
            .lines()
            .flatMap { $0 }
    } catch {
        Logger.error(error)
        exit(Int32(error._code))
    }
}()

let semaphore = DispatchSemaphore(value: 0)

// perform jira search
let jira = Jira(host: host.value)
jira.search(query: jql.value) { (data, error) in
    guard error == nil else {
        Logger.error(error)
        exit(Int32(error!._code))
    }
    
    guard let data = data,
        let json = try! JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Logger.error("unable to decode json data")
            exit(1)
    }
    
    // decode JSON to array of `Issue`s
    let issues: [Issue]
    do {
        issues = try unbox(dictionary: json, atKey: "issues")
    } catch {
        Logger.error("unboxing error", error)
        exit(Int32(error._code))
    }
    
    // if no issues to send, then exit without error
    guard issues.count > 0 else {
        Logger.info("nothing to send, exiting")
        exit(0)
    }
    
    // build HTMLMessage
    let from = "noreply@cnnxcodeserver.com"
    let subject = "tvOS \(version.value) Build (\(build.value))"
    let html = HTMLReport(version: version.value, build: build.value, issueGroups: issues.group { $0.type.name })
    let message = HTMLMessage(sender: from, recipients: recipients, subject: subject, body: String(describing: html))
    
    // send email using `sendmail`
    let sendmail = Sendmail()
    sendmail.send(message: message)
    
    // signal semaphore, increment count
    _ = semaphore.signal()
}

// semaphore so script does not exit before completing
semaphore.wait()
