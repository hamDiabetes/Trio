import CoreData
import Foundation
import Swinject
import Testing

@testable import Trio

@Suite("Override Storage Tests", .serialized) struct OverrideStorageTests: Injectable {
    @Injected() var storage: OverrideStorage!
    let resolver: Resolver
    var coreDataStack: CoreDataStack!
    var testContext: NSManagedObjectContext!

    init() async throws {
        // Create test context
        // As we are only using this single test context to initialize our in-memory DeterminationStorage we need to perform the Unit Tests serialized
        coreDataStack = try await CoreDataStack.createForTests()
        testContext = coreDataStack.newTaskContext()

        // Create assembler with test assembly
        let assembler = Assembler([
            StorageAssembly(),
            ServiceAssembly(),
            APSAssembly(),
            NetworkAssembly(),
            UIAssembly(),
            SecurityAssembly(),
            TestAssembly(testContext: testContext) // Add our test assembly last to override Storage
        ])

        resolver = assembler.resolver
        injectServices(resolver)
    }

    @Test("Storage is correctly initialized") func testStorageInitialization() {
        // Verify storage exists
        #expect(storage != nil, "OverrideStorage should be injected")

        // Verify it's the correct type
        #expect(storage is BaseOverrideStorage, "Storage should be of type BaseOverrideStorage")
    }

    @Test("Store and retrieve override") func testStoreAndRetrieveOverride() async throws {
        // Given
        let testOverride = Override(
            name: "Test Override",
            enabled: false,
            date: Date(),
            duration: 120,
            indefinite: false,
            percentage: 130,
            smbIsOff: true,
            isPreset: false,
            id: UUID().uuidString,
            overrideTarget: true,
            target: 110,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 1,
            end: 2,
            smbMinutes: 100,
            uamMinutes: 120
        )

        // When
        try await storage.storeOverride(override: testOverride)

        // Then verify stored entries
        let storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "name == %@", "Test Override"),
            key: "date",
            ascending: false
        ) as? [OverrideStored]

        #expect(storedEntries?.isEmpty == false, "Should have stored entries")
        #expect(storedEntries?.count == 1, "Should have exactly one entry")
        let storedOverride = storedEntries?.first
        #expect(storedOverride?.name == "Test Override", "Name should match")
        #expect(storedOverride?.percentage == 130, "Percentage should match")
        #expect(storedOverride?.target?.decimalValue == 110, "Target should match")
        #expect(storedOverride?.isPreset == false, "isPreset should match")
    }

    @Test("Store SMB with high glucose target, dropping out-of-range values") func testStoreSmbHighBgTarget() async throws {
        func makeOverride(name: String, advancedSettings: Bool, smbHighBgTarget: Decimal?) -> Override {
            Override(
                name: name,
                enabled: false,
                date: Date(),
                duration: 0,
                indefinite: true,
                percentage: 100,
                smbIsOff: false,
                isPreset: true,
                id: UUID().uuidString,
                overrideTarget: false,
                target: 0,
                advancedSettings: advancedSettings,
                isfAndCr: false,
                isf: false,
                cr: false,
                smbIsScheduledOff: false,
                start: 0,
                end: 0,
                smbMinutes: 30,
                uamMinutes: 120,
                smbHighBgTarget: smbHighBgTarget
            )
        }

        let cases: [(String, Bool, Decimal?, Decimal?)] = [
            ("HighBg Valid", true, 150, 150),
            ("HighBg Unset", true, nil, nil),
            ("HighBg Too Low", true, 90, nil),
            ("HighBg Too High", true, 260, nil),
            ("HighBg 119", true, 119, nil),
            ("HighBg 120", true, 120, 120),
            ("HighBg 200", true, 200, 200),
            ("HighBg 201", true, 201, nil),
            ("HighBg No Advanced", false, 150, nil)
        ]

        for (name, advancedSettings, input, expected) in cases {
            try await storage.storeOverride(
                override: makeOverride(name: name, advancedSettings: advancedSettings, smbHighBgTarget: input)
            )
            let stored = try await coreDataStack.fetchEntitiesAsync(
                ofType: OverrideStored.self,
                onContext: testContext,
                predicate: NSPredicate(format: "name == %@", name),
                key: "date",
                ascending: false
            ) as? [OverrideStored]
            let value = await testContext.perform { stored?.first?.smbHighBgTarget?.decimalValue }
            #expect(stored?.count == 1, "\(name) should be stored once")
            #expect(value == expected, "\(name) should store \(String(describing: expected))")
        }
    }

    @Test(
        "Copying a running override keeps the SMB with high glucose target"
    ) @MainActor func testCopyRunningOverrideSmbHighBgTarget(
    ) async throws {
        let source = OverrideStored(context: testContext)
        source.id = UUID().uuidString
        source.name = "Copy Source"
        source.date = Date()
        source.advancedSettings = true
        source.smbHighBgTarget = 150

        let copyID = await storage.copyRunningOverride(source)
        let viewContext = CoreDataStack.shared.persistentContainer.viewContext
        let copy = try viewContext.existingObject(with: copyID) as? OverrideStored
        #expect(copy?.smbHighBgTarget?.decimalValue == 150)
        #expect(copy?.advancedSettings == true)

        if let copy {
            viewContext.delete(copy)
            try viewContext.save()
        }
        testContext.delete(source)
    }

    @Test("Algorithm input carries the active override's SMB with high glucose target") func testOrefVariablesSmbHighBgTarget(
    ) async throws {
        try await testContext.perform {
            let active = OverrideStored(context: self.testContext)
            active.id = UUID().uuidString
            active.name = "Active Meal"
            active.date = Date()
            active.enabled = true
            active.indefinite = true
            active.percentage = 100
            active.advancedSettings = true
            active.smbMinutes = 30
            active.uamMinutes = 120
            active.smbHighBgTarget = 150
            try self.testContext.save()
        }

        let openAPS = OpenAPS(
            storage: BaseFileStorage(),
            tddStorage: resolver.resolve(TDDStorage.self)!,
            glucoseStorage: resolver.resolve(GlucoseStorage.self)!,
            carbsStorage: resolver.resolve(CarbsStorage.self)!
        )
        let raw = try await openAPS.prepareTrioCustomOrefVariables(on: testContext)
        let variables = try JSONCoding.decoder.decode(TrioCustomOrefVariables.self, from: Data(raw.utf8))

        #expect(variables.useOverride == true)
        #expect(variables.advancedSettings == true)
        #expect(variables.uamMinutes == 120)
        #expect(variables.smbHighBgTarget == 150)

        try await testContext.perform {
            let request = OverrideStored.fetchRequest()
            request.predicate = NSPredicate(format: "name == %@", "Active Meal")
            try self.testContext.fetch(request).forEach { self.testContext.delete($0) }
            try self.testContext.save()
        }
    }

    @Test("Store and retrieve override preset") func testStoreAndRetrieveOverridePreset() async throws {
        // Given
        let testPreset = Override(
            name: "Test Preset",
            enabled: false,
            date: Date(),
            duration: 0,
            indefinite: true,
            percentage: 120,
            smbIsOff: true,
            isPreset: true,
            id: UUID().uuidString,
            overrideTarget: true,
            target: 110,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 1,
            end: 2,
            smbMinutes: 100,
            uamMinutes: 120
        )

        // When
        try await storage.storeOverride(override: testPreset)
        let presetIDs = try await storage.fetchForOverridePresets()

        // Then
        #expect(!presetIDs.isEmpty, "Should have stored preset")

        let storedPresets = try await testContext.perform {
            try presetIDs.map { try testContext.existingObject(with: $0) as! OverrideStored }
        }

        #expect(storedPresets.count >= 1, "Should have at least one preset")
        let storedPreset = storedPresets.first { $0.name == "Test Preset" }
        #expect(storedPreset != nil, "Should find the test preset")
        #expect(storedPreset?.isPreset == true, "Should be marked as preset")
        #expect(storedPreset?.indefinite == true, "Should be indefinite")
        #expect(storedPreset?.percentage == 120, "Percentage should match")
    }

    @Test("Delete override preset") func testDeleteOverridePreset() async throws {
        // Given
        let testPreset = Override(
            name: "Delete Test",
            enabled: false,
            date: Date(),
            duration: 0,
            indefinite: true,
            percentage: 120,
            smbIsOff: true,
            isPreset: true,
            id: UUID().uuidString,
            overrideTarget: true,
            target: 110,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 1,
            end: 2,
            smbMinutes: 100,
            uamMinutes: 120
        )

        // Store the preset
        try await storage.storeOverride(override: testPreset)

        // Get the stored preset's ObjectID
        let storedEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "name == %@", "Delete Test"),
            key: "date",
            ascending: false
        ) as? [OverrideStored]

        guard let objectID = storedEntries?.first?.objectID else {
            throw TestError("Failed to get stored preset's ObjectID")
        }

        // When
        await storage.deleteOverridePreset(objectID)

        // Then verify deletion
        let remainingEntries = try await coreDataStack.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: testContext,
            predicate: NSPredicate(format: "name == %@", "Delete Test"),
            key: "date",
            ascending: false
        ) as? [OverrideStored]

        #expect(remainingEntries?.isEmpty == true, "Should have no entries after deletion")
    }

    @Test("Get overrides not yet uploaded to Nightscout") func testGetOverridesNotYetUploadedToNightscout() async throws {
        // Given
        let testOverride = Override(
            name: "NS Test",
            enabled: true, // getOverridesNotYetUploadedToNightscout() fetches only active overrides
            date: Date(),
            duration: 90,
            indefinite: false,
            percentage: 120,
            smbIsOff: true,
            isPreset: true,
            id: UUID().uuidString,
            overrideTarget: true,
            target: 110,
            advancedSettings: false,
            isfAndCr: false,
            isf: false,
            cr: false,
            smbIsScheduledOff: false,
            start: 1,
            end: 2,
            smbMinutes: 100,
            uamMinutes: 120
        )

        // When
        try await storage.storeOverride(override: testOverride)

        let notUploadedOverrides = try await storage.getOverridesNotYetUploadedToNightscout()

        // Then
        #expect(!notUploadedOverrides.isEmpty == true, "Should have overrides not uploaded to NS")
        #expect(notUploadedOverrides[0].notes == "NS Test", "Override name should match")
        #expect(notUploadedOverrides[0].duration == 90, "Duration should match")
        #expect(notUploadedOverrides[0].eventType == .nsExercise, "Event type should be exercise")
    }

    @Test("Get override runs not yet uploaded to Nightscout") func testGetOverrideRunsNotYetUploadedToNightscout() async throws {
        // Given
        let now = Date()
        let hour: TimeInterval = 60 * 60
        let recentStart = now.addingTimeInterval(-2 * hour)
        let longRunningStart = now.addingTimeInterval(-72 * hour)

        await testContext.perform {
            let recent = OverrideRunStored(context: self.testContext)
            recent.id = UUID()
            recent.name = "Recent"
            recent.startDate = recentStart
            recent.endDate = now.addingTimeInterval(-hour)
            recent.isUploadedToNS = false

            let longRunning = OverrideRunStored(context: self.testContext)
            longRunning.id = UUID()
            longRunning.name = "Long running"
            longRunning.startDate = longRunningStart
            longRunning.endDate = now.addingTimeInterval(-hour)
            longRunning.isUploadedToNS = false

            let stale = OverrideRunStored(context: self.testContext)
            stale.id = UUID()
            stale.name = "Stale"
            stale.startDate = now.addingTimeInterval(-72 * hour)
            stale.endDate = now.addingTimeInterval(-48 * hour)
            stale.isUploadedToNS = false

            let uploaded = OverrideRunStored(context: self.testContext)
            uploaded.id = UUID()
            uploaded.name = "Uploaded"
            uploaded.startDate = recentStart
            uploaded.endDate = now.addingTimeInterval(-hour)
            uploaded.isUploadedToNS = true

            try? self.testContext.save()
        }

        // When
        let runs = try await storage.getOverrideRunsNotYetUploadedToNightscout()

        // Then
        #expect(
            runs.compactMap(\.notes).sorted() == ["Long running", "Recent"],
            "Runs that ended within the last day are uploaded, whenever they started"
        )

        let longRunning = try #require(runs.first { $0.notes == "Long running" })
        #expect(longRunning.createdAt == longRunningStart, "created_at is the run's start")
        #expect(longRunning.duration == 71 * 60, "Duration spans the whole run")
        #expect(longRunning.eventType == .nsExercise, "Event type should be exercise")
    }
}
