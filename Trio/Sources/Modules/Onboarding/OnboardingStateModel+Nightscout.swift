import Combine
import Foundation
import SwiftUI

// MARK: - Setup Nightscout Connection

extension Onboarding.StateModel {
    func connectToNightscout() {
        if let CheckURL = nightscoutUrl.last, CheckURL == "/" {
            let fixedURL = nightscoutUrl.dropLast()
            nightscoutUrl = String(fixedURL)
        }

        guard let nightscoutUrl = URL(string: nightscoutUrl), self.nightscoutUrl.hasPrefix("https://") else {
            nightscoutResponseMessage = "Invalid URL"
            isValidNightscoutURL = false
            return
        }

        isConnectingToNS = true
        isValidNightscoutURL = true
        nightscoutResponseMessage = ""

        NightscoutAPI(url: nightscoutUrl, secret: nightscoutSecret).checkConnection()
            .receive(on: DispatchQueue.main)
            .sink { completion in
                switch completion {
                case .finished: break
                case let .failure(error):
                    self.nightscoutResponseMessage = "Error: \(error.localizedDescription)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.isConnectingToNS = false
                }
            } receiveValue: {
                self.keychain.setValue(self.nightscoutUrl, forKey: NightscoutConfig.Config.urlKey)
                self.keychain.setValue(self.nightscoutSecret, forKey: NightscoutConfig.Config.secretKey)
                self.isConnectedToNS = true
            }
            .store(in: &lifetime)
    }

    var nightscoutAPI: NightscoutAPI? {
        guard let urlString = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey),
              let url = URL(string: urlString),
              let secret = keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
        else {
            return nil
        }
        return NightscoutAPI(url: url, secret: secret)
    }

    func importSettingsFromNightscout(currentStep: Binding<OnboardingStep>) async {
        guard nightscoutAPI != nil, isConnectedToNS else {
            return
        }

        nightscoutImportStatus = .running

        do {
            guard let fetchedProfile = await nightscoutManager.importSettings() else {
                throw NSError(
                    domain: "ImportError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot find the Nightscout Profile named \"default\"."]
                )
            }

            let settings = try NightscoutProfileConverter.therapySettings(from: fetchedProfile)

            // Store therapy settings in-memory in state model for further review
            finalizeImport(
                targets: settings.targets,
                basals: settings.basals,
                carbRatios: settings.carbRatios,
                sensitivities: settings.sensitivities,
                userPreferredUnitsFromImport: settings.units,
                currentStep: currentStep
            )
        } catch {
            await MainActor.run {
                self.nightscoutImportError = NightscoutImportError(message: error.localizedDescription)
                self.nightscoutImportStatus = .failed
                debug(.service, "Settings import failed with error: \(error)")
            }
        }
    }

    fileprivate func finalizeImport(
        targets targetsProfile: BGTargets,
        basals: [BasalProfileEntry],
        carbRatios carbratiosProfile: CarbRatios,
        sensitivities sensitivitiesProfile: InsulinSensitivities,
        userPreferredUnitsFromImport: String,
        currentStep: Binding<OnboardingStep>
    ) {
        /// First, very important: assign `units` so that `xxxRateValues` contain the proper values
        /// and array has the correct number of elements.
        /// If not done here, this may lead to index-out-of-bound errors for users importing mmol/L settings.
        units = userPreferredUnitsFromImport.contains("mmol") ? .mmolL : .mgdL

        // Parse: targetsProfile → targetItems
        targetItems = targetsProfile.targets.map { entry in
            let timeIndex = targetTimeValues.firstIndex(where: { Int($0) == entry.offset * 60 }) ?? 0
            let lowIndex = targetRateValues.enumerated().min(by: {
                abs($0.element - entry.low) < abs($1.element - entry.low)
            })?.offset ?? 0

            return TargetsEditor.Item(lowIndex: lowIndex, highIndex: lowIndex, timeIndex: timeIndex)
        }
        initialTargetItems = targetItems

        // Parse: basals → basalProfileItems
        basalProfileItems = basals.map { entry in
            let timeIndex = basalProfileTimeValues.firstIndex(where: { Int($0) == entry.minutes * 60 }) ?? 0
            let rateIndex = basalProfileRateValues.enumerated().min(by: {
                abs($0.element - entry.rate) < abs($1.element - entry.rate)
            })?.offset ?? 0
            return BasalProfileEditor.Item(rateIndex: rateIndex, timeIndex: timeIndex)
        }
        initialBasalProfileItems = basalProfileItems

        // Parse: carbratiosProfile → carbRatioItems
        carbRatioItems = carbratiosProfile.schedule.map { entry in
            let timeIndex = carbRatioTimeValues.firstIndex(where: { Int($0) == entry.offset * 60 }) ?? 0
            let rateIndex = carbRatioRateValues.enumerated().min(by: {
                abs($0.element - entry.ratio) < abs($1.element - entry.ratio)
            })?.offset ?? 0
            return CarbRatioEditor.Item(rateIndex: rateIndex, timeIndex: timeIndex)
        }
        initialCarbRatioItems = carbRatioItems

        // Parse: sensitivitiesProfile → isfItems
        isfItems = sensitivitiesProfile.sensitivities.map { entry in
            let timeIndex = isfTimeValues.firstIndex(where: { Int($0) == entry.offset * 60 }) ?? 0
            let rateIndex = isfRateValues.enumerated().min(by: {
                abs($0.element - entry.sensitivity) < abs($1.element - entry.sensitivity)
            })?.offset ?? 0

            return ISFEditor.Item(rateIndex: rateIndex, timeIndex: timeIndex)
        }
        initialISFItems = isfItems

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.nightscoutImportStatus = .finished
            // navigate to the next onboarding step
            if let next = currentStep.wrappedValue.next {
                currentStep.wrappedValue = next
            }
        }
    }

    fileprivate func offset(_ string: String) -> Int {
        NightscoutProfileConverter.offset(string)
    }

    enum ImportStatus {
        case none
        case running
        case finished
        case failed
    }
}

struct NightscoutImportError: Identifiable {
    let id = UUID()
    let message: String
}
