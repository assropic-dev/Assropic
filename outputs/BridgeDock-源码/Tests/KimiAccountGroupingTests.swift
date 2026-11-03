import Foundation

@main
struct KimiAccountGroupingTests {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        assertions += 1
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) {
        assertions += 1
        do {
            try operation()
            preconditionFailure(message)
        } catch {}
    }

    static func codeAccount(disabled: Bool = false, prefix: String = "kimi-code") -> Account {
        Account(["name": "synthetic-kimi-identity", "provider": "kimi", "email": "kimi@example.invalid",
                 "status": "active", "auth_index": "synthetic-code-index", "note": "Kimi Code",
                 "prefix": prefix, "disabled": disabled])
    }

    static func workChannel(enabled: Bool = true) -> Channel {
        var channel = Channel()
        // Deliberately share the bare identity and display-name stem with Code.
        // Both routing and quota identities must still include their source type.
        channel.id = "synthetic-kimi-identity"
        channel.name = "Kimi Work"
        channel.prefix = "kimi-work"
        channel.credentialSource = "kimi-work-desktop"
        channel.desktopAccountHash = String(repeating: "a", count: 64)
        channel.baseURL = "https://agent-gw.kimi.com/coding/v1"
        channel.wire = .chat
        channel.modelLines = "shared-model"
        channel.balanceMode = .kimiWork
        channel.enabled = enabled
        return channel
    }

    static func main() throws {
        let code = codeAccount()
        let work = workChannel()
        let codeModel = ModelItem(id: "kimi-code/shared-model", owner: "kimi")
        let workModel = ModelItem(id: "kimi-work/shared-model", owner: "kimi")
        let rawModels = [codeModel, workModel]
        var settings = AppSettings()
        settings.channels = [work]

        let catalog = ModelPublishing.catalog(rawModels: rawModels, settings: settings, accounts: [code])
        check(catalog.count == 2, "Same-name Code and Work models remain separate catalog entries")
        check(Set(catalog.map(\.id)) == Set([codeModel.id, workModel.id]), "Each source preserves its actual core routing ID")
        check(Set(catalog.map(\.publicID)).count == 2, "Code and Work receive distinct public IDs even with the same Kimi name stem")
        check(Set(catalog.map(\.modelName)) == ["shared-model"], "The distinction comes from source identity, not renaming the upstream model")
        check(Set(catalog.map(\.sourceName)) == ["Kimi Code", "Kimi Work"], "The catalog preserves separate billing-source labels")
        check(catalog.allSatisfy(\.isEnabled), "Both sources are initially published")

        settings.publishedModelIDs = [codeModel.id]
        let onlyCodeSelected = ModelPublishing.catalog(rawModels: rawModels, settings: settings, accounts: [code])
        check(onlyCodeSelected.first { $0.id == codeModel.id }?.isEnabled == true, "Selecting Code publishes Code")
        check(onlyCodeSelected.first { $0.id == workModel.id }?.isEnabled == false, "Selecting Code does not also select same-name Work")
        settings.publishedModelIDs = [workModel.id]
        let onlyWorkSelected = ModelPublishing.catalog(rawModels: rawModels, settings: settings, accounts: [code])
        check(onlyWorkSelected.first { $0.id == workModel.id }?.isEnabled == true, "Selecting Work publishes Work")
        check(onlyWorkSelected.first { $0.id == codeModel.id }?.isEnabled == false, "Selecting Work does not also select same-name Code")
        check(Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.publicID) }) ==
              Dictionary(uniqueKeysWithValues: onlyWorkSelected.map { ($0.id, $0.publicID) }),
              "Changing publication selection does not rename either route")

        // The core removes a disabled source from its model-list response. Exercise
        // each resulting snapshot while retaining the saved publication selections.
        settings.publishedModelIDs = [codeModel.id, workModel.id]
        settings.channels = [workChannel(enabled: false)]
        let workDisabled = ModelPublishing.catalog(rawModels: [codeModel], settings: settings, accounts: [code])
        check(workDisabled.count == 1 && workDisabled[0].id == codeModel.id && workDisabled[0].isEnabled,
              "Disabling Work leaves the selected Code route available")
        check(workDisabled[0].sourceName == "Kimi Code", "Disabling Work does not reassign Code to the Work source")

        settings.channels = [work]
        let codeDisabled = ModelPublishing.catalog(rawModels: [workModel], settings: settings, accounts: [codeAccount(disabled: true)])
        check(codeDisabled.count == 1 && codeDisabled[0].id == workModel.id && codeDisabled[0].isEnabled,
              "Disabling Code leaves the selected Work route available")
        check(codeDisabled[0].sourceName == "Kimi Work", "Disabling Code does not reassign Work to the Code source")
        let reenabled = ModelPublishing.catalog(rawModels: rawModels, settings: settings, accounts: [code])
        check(reenabled.count == 2 && reenabled.allSatisfy(\.isEnabled), "Re-enabling either source restores its independent saved selection")

        let codeQuota = QuotaTarget(account: code)
        let workQuota = QuotaTarget(channel: work)
        check(codeQuota.id == "account:synthetic-kimi-identity", "Code quota uses the account namespace")
        check(workQuota.id == "channel:synthetic-kimi-identity", "Work quota uses the channel namespace")
        check(codeQuota.id != workQuota.id, "Even identical bare identities cannot combine the two quota caches")
        check(codeQuota.account?.id == code.id && codeQuota.channel == nil, "Code quota dispatches through the subscription account")
        check(workQuota.channel?.id == work.id && workQuota.account == nil, "Work quota dispatches through its dedicated channel")
        check(workQuota.channel?.isKimiWork == true && workQuota.channel?.balanceMode == .kimiWork,
              "Work retains its dedicated membership billing mode")
        check(QuotaTarget(channel: workChannel(enabled: false)).fingerprint != workQuota.fingerprint,
              "Changing Work availability invalidates only its own quota state")
        check(QuotaTarget(account: codeAccount(disabled: true)).fingerprint != codeQuota.fingerprint,
              "Changing Code availability invalidates only its own quota state")

        var secondWork = work
        secondWork.id = "synthetic-second-work"
        secondWork.prefix = "kimi-work-2"
        let overlappingCode = codeAccount(prefix: "kimi-work")
        check(Channel.unusedPrefix("kimi-work", channels: [secondWork], accounts: [overlappingCode]) == "kimi-work-3",
              "New Work prefixes skip both existing Code and channel prefixes")
        check(Channel.unusedPrefix("kimi-work", channels: [], accounts: [codeAccount(disabled: true, prefix: "kimi-work")]) == "kimi-work-2",
              "Disabled Code accounts keep their reserved prefix")
        secondWork.enabled = false
        check(Channel.unusedPrefix("kimi-work", channels: [secondWork], accounts: [codeAccount(disabled: true, prefix: "kimi-work")]) == "kimi-work-3",
              "Disabled accounts and channels both retain their independent routing names")
        check(Channel.unusedPrefix("kimi-work", channels: [], accounts: [code]) == "kimi-work",
              "An unused Work prefix remains unchanged")
        rejects("Work cannot reuse an active Code account prefix") {
            _ = try work.validated(channels: [], accounts: [overlappingCode])
        }
        rejects("Work cannot reuse a disabled Code account prefix") {
            _ = try work.validated(channels: [], accounts: [codeAccount(disabled: true, prefix: "kimi-work")])
        }
        let savedWork = try work.validated(channels: [work], accounts: [code])
        check(savedWork == work, "Saving an existing Work channel accepts its own unchanged prefix")
        var duplicatedWork = work
        duplicatedWork.id = "synthetic-duplicate-work"
        rejects("A different channel cannot reuse the existing Work prefix") {
            _ = try duplicatedWork.validated(channels: [work], accounts: [code])
        }
        let defaultWork = try work.validated()
        check(defaultWork == work, "Existing default validation calls remain compatible")
        var ordinary = Channel()
        ordinary.name = "Ordinary API"
        ordinary.baseURL = "https://example.invalid/v1"
        ordinary.apiKey = "synthetic-api-key"
        ordinary.prefix = "ordinary"
        ordinary.modelLines = "shared-model"
        let defaultOrdinary = try ordinary.validated()
        check(defaultOrdinary == ordinary, "Ordinary API channels still validate without routing collections")
        print("PASS \(assertions) Kimi account grouping, model isolation and quota identity assertions; synthetic data only.")
    }
}
