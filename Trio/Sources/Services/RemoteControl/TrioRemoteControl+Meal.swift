import Foundation

extension TrioRemoteControl {
    func handleMealCommand(_ payload: CommandPayload) async throws {
        guard payload.carbs != nil || payload.fat != nil || payload.protein != nil else {
            await logError("Command rejected: meal data is incomplete or invalid.", payload: payload)
            return
        }

        let carbsDecimal = payload.carbs != nil ? Decimal(payload.carbs!) : nil
        let fatDecimal = payload.fat != nil ? Decimal(payload.fat!) : nil
        let proteinDecimal = payload.protein != nil ? Decimal(payload.protein!) : nil

        let settings = await TrioApp.resolver.resolve(SettingsManager.self)?.settings
        let maxCarbs = settings?.maxCarbs ?? Decimal(0)
        let maxFat = settings?.maxFat ?? Decimal(0)
        let maxProtein = settings?.maxProtein ?? Decimal(0)

        if let carbs = carbsDecimal, carbs > maxCarbs {
            await logError(
                "Command rejected: carbs amount (\(carbs)g) exceeds the maximum allowed (\(maxCarbs)g).",
                payload: payload
            )
            return
        }
        if let fat = fatDecimal, fat > maxFat {
            await logError("Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(maxFat)g).", payload: payload)
            return
        }
        if let protein = proteinDecimal, protein > maxProtein {
            await logError(
                "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(maxProtein)g).",
                payload: payload
            )
            return
        }

        let payloadDate = Date(timeIntervalSince1970: payload.timestamp)
        let taskContext = CoreDataStack.shared.newTaskContext()
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self, onContext: taskContext, predicate: NSPredicate(
                format: "date > %@",
                payloadDate as NSDate
            ), key: "date", ascending: false
        )

        let hasNewerCarbEntries = await taskContext.perform {
            (results as? [CarbEntryStored])?.isEmpty == false
        }
        if hasNewerCarbEntries {
            await logError(
                "Command rejected: newer carb entries have been logged since the command was sent.",
                payload: payload
            )
            return
        }

        let actualDate = payload.scheduledTime.map { Date(timeIntervalSince1970: $0) }

        let mealEntry = CarbsEntry(
            id: UUID().uuidString, createdAt: Date(), actualDate: actualDate,
            carbs: carbsDecimal ?? 0, fat: fatDecimal, protein: proteinDecimal,
            note: "Remote meal command", enteredBy: CarbsEntry.local, isFPU: false,
            fpuID: fatDecimal ?? 0 > 0 || proteinDecimal ?? 0 > 0 ? UUID().uuidString : nil
        )

        // Resolve any follow-up bolus before storing the meal so the recommendation is not skewed by the
        // just-stored carbs, matching the Treatments UI's compute-then-save order.
        let bolusPlan = await resolveMealBolusPlan(payload, carbs: carbsDecimal ?? 0, mealDate: actualDate)

        try await carbsStorage.storeCarbs([mealEntry], areFetchedFromRemote: false)

        switch bolusPlan {
        case .none:
            await logSuccess(
                "Remote command processed successfully. \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: "Meal logged"
            )

        case .explicit:
            try await handleBolusCommand(payload)

        case let .reject(reason):
            await logError(reason, payload: payload)

        case let .skip(reason):
            await logSuccess(reason, payload: payload, customNotificationMessage: reason, uploadNote: true)

        case let .advise(amount):
            let message = "Recommended bolus: \(amount) U for \(carbsDecimal ?? 0) g. Review and confirm in Loop Follow."
            await logSuccess(
                message,
                payload: payload,
                customNotificationMessage: message,
                uploadNote: true,
                recommendedBolus: amount
            )

        case let .recommended(amount):
            do {
                try await enactValidatedBolus(
                    amount: amount,
                    payload: payload,
                    successNotificationMessage: "Auto-bolus started: \(amount) U"
                )
            } catch {
                await logError(
                    "Auto-bolus failed after the meal was stored: \(error.localizedDescription). The meal was logged, but no insulin was delivered by this command.",
                    payload: payload
                )
            }
        }
    }

    private enum MealBolusPlan {
        case none
        case explicit
        case reject(String)
        case skip(String)
        case advise(Decimal)
        case recommended(Decimal)
    }

    // Only a meal timed for roughly now is bolused; an upfront bolus for future or backdated carbs would
    // over-deliver once the loop accounts for them.
    private enum AutoBolusMealScheduling {
        static let futureTolerance: TimeInterval = 10 * 60
        static let pastTolerance: TimeInterval = 10 * 60
    }

    private func resolveMealBolusPlan(_ payload: CommandPayload, carbs: Decimal, mealDate: Date?) async -> MealBolusPlan {
        let wantsRecommendedBolus = payload.useRecommendedBolus == true
        let hasExplicitBolus = payload.bolusAmount != nil

        if hasExplicitBolus, wantsRecommendedBolus {
            return .reject(
                "Command rejected: a meal cannot request both an explicit bolus amount and Trio's recommended bolus. The meal was logged, but no bolus was given."
            )
        }
        if hasExplicitBolus {
            return .explicit
        }
        guard wantsRecommendedBolus else {
            return .none
        }

        let mode = RemoteMealBolusMode.current()
        guard mode != .off else {
            return .skip(
                "The meal was logged. No bolus was given because Remote Meal Bolus is set to Off in Trio's Remote Control settings."
            )
        }

        let now = Date()
        let mealTime = mealDate ?? now
        let offset = mealTime.timeIntervalSince(now)

        if offset > AutoBolusMealScheduling.futureTolerance {
            return .skip(
                "The meal was logged. Auto-bolus was skipped because the meal is scheduled in the future; enact a bolus when the meal is eaten."
            )
        }
        if offset < -AutoBolusMealScheduling.pastTolerance {
            return .skip(
                "The meal was logged. Auto-bolus was skipped because the meal is backdated; the loop is already accounting for these carbs, so no upfront bolus was given."
            )
        }

        guard let apsManager = await TrioApp.resolver.resolve(APSManager.self),
              let bolusCalculationManager = await TrioApp.resolver.resolve(BolusCalculationManager.self)
        else {
            return .reject(
                "Error: unable to compute the recommended bolus because required services are not available. The meal was logged, but no bolus was given."
            )
        }

        let result = await bolusCalculationManager.handleBolusCalculation(
            carbs: carbs,
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: nil,
            simulatedCOB: nil,
            isBackdated: false
        )

        // insulinCalculated is already safety-clamped (to 0 below limits, stale loop, or IOB cap) and rounded
        // to the pump increment.
        let recommendedBolus = result.insulinCalculated
        guard recommendedBolus > 0 else {
            return .skip(
                "The meal was logged. Auto-bolus recommended no insulin for this meal. This is expected when glucose or a prediction is below the safety limit, the loop is stale, or IOB is already at its limit."
            )
        }

        return mode == .requireReview ? .advise(recommendedBolus) : .recommended(recommendedBolus)
    }
}
