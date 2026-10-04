import SwiftUI
import Swinject

extension Profiles {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        @State private var profileToDelete: Item?

        var body: some View {
            Form {
                switch state.loadState {
                case .idle,
                     .loading:
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading profiles from Nightscout").padding(.leading, 8)
                        }
                    }.listRowBackground(Color.chart)
                case let .failed(message):
                    Section(header: Text("Nightscout")) {
                        Text(message).foregroundStyle(.red)
                        Button("Try Again") { Task { await state.load() } }
                    }.listRowBackground(Color.chart)
                case .loaded:
                    interruptedSection
                    currentSection
                    profilesSection
                    orphanedSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.automatic)
            .onAppear(perform: configureView)
            .sheet(isPresented: $state.showSaveSheet) { saveSheet }
            .sheet(
                isPresented: Binding(
                    get: { state.pendingSwitch != nil },
                    set: { if !$0 { state.pendingSwitch = nil } }
                )
            ) { switchSheet }
            .alert(
                "Profile Switch Did Not Finish",
                isPresented: $state.showInterruptedAlert
            ) {
                Button("OK") { state.showInterruptedAlert = false }
            } message: {
                Text(interruptedMessage)
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(
                    get: { state.errorMessage != nil },
                    set: { if !$0 { state.errorMessage = nil } }
                )
            ) {
                Button("OK") { state.errorMessage = nil }
            } message: {
                Text(state.errorMessage ?? "")
            }
            .alert(
                "Delete Profile",
                isPresented: Binding(get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } })
            ) {
                Button("Cancel", role: .cancel) { profileToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let item = profileToDelete {
                        Task { await state.delete(item) }
                    }
                    profileToDelete = nil
                }
            } message: {
                Text("\(profileToDelete?.name ?? "") will be removed from Nightscout. Your current settings are not changed.")
            }
        }

        private var currentSection: some View {
            Section(header: Text("Current Settings")) {
                if let applied = state.applied {
                    HStack {
                        Text(applied.name)
                        Spacer()
                        if state.appliedProfileEdited {
                            Text("Edited").foregroundStyle(.orange)
                        }
                    }
                    Text("Applied \(applied.appliedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if state.appliedProfileEdited {
                        Text("Your therapy settings have changed since this profile was applied.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No profile applied").foregroundStyle(.secondary)
                }

                Button("Save Current Settings as Profile") {
                    state.newProfileName = ""
                    state.showSaveSheet = true
                }
            }.listRowBackground(Color.chart)
        }

        private var profilesSection: some View {
            Section(
                header: Text("Nightscout Profiles"),
                footer: Text(
                    "Profiles are stored in Nightscout. Trio's own settings are published separately and are not shown here."
                )
            ) {
                if state.items.isEmpty {
                    Text("No saved profiles").foregroundStyle(.secondary)
                } else {
                    ForEach(state.items) { item in
                        // A Button rather than a tap gesture on the row: the gesture carries no
                        // accessibility trait, so the row was unreachable to VoiceOver.
                        Button {
                            Task { await state.prepareSwitch(to: item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    if state.applied?.name == item.name {
                                        Image(systemName: "checkmark").foregroundStyle(.blue)
                                    }
                                }
                                if item.trioSettings == nil {
                                    Text("Therapy settings only — no Trio algorithm settings saved")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(item.name)
                        .swipeActions {
                            Button("Delete", role: .destructive) { profileToDelete = item }
                        }
                    }
                }
            }.listRowBackground(Color.chart)
        }

        @ViewBuilder private var orphanedSection: some View {
            if !state.unreadableProfiles.isEmpty {
                Section(
                    header: Text("Unreadable Profiles"),
                    footer: Text(
                        "Nightscout has these profiles but Trio cannot read them, so they cannot be switched to. They are left unchanged in Nightscout."
                    )
                ) {
                    ForEach(state.unreadableProfiles, id: \.self) { Text($0) }
                }.listRowBackground(Color.chart)
            }

            if !state.unmatchedSettings.isEmpty {
                Section(
                    header: Text("Unmatched Settings"),
                    footer: Text(
                        "Trio has algorithm settings saved for these names, but Nightscout no longer has a profile with them. This happens when a profile is renamed or deleted in Nightscout."
                    )
                ) {
                    ForEach(state.unmatchedSettings, id: \.self) { Text($0) }
                }.listRowBackground(Color.chart)
            }
        }

        /// Stays until a switch succeeds or someone confirms the pump, because dismissing an alert is not
        /// the same as the pump and Trio agreeing again.
        @ViewBuilder private var interruptedSection: some View {
            if state.interrupted != nil {
                Section(header: Text("Last Switch Did Not Finish")) {
                    Text(interruptedMessage).foregroundStyle(.orange)
                    Text("Switching again rewrites your pump's basal schedule.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("I've Checked My Pump's Basal Rates") { state.dismissInterrupted() }
                }.listRowBackground(Color.chart)
            }
        }

        /// Says which side of the switch is known to have happened, because after an interrupted switch
        /// the pump and Trio can be running different settings.
        private var interruptedMessage: String {
            guard let marker = state.interrupted else { return "" }
            let stage: String
            if marker.pumpAcceptedAfterTimeout == true {
                stage = String(
                    localized: "Switching to \(marker.profileName) timed out, and your pump accepted the new basal rates afterwards. Your pump has the new basal rates but Trio's therapy settings were not changed."
                )
            } else if !marker.pumpWriteConfirmed {
                stage = String(
                    localized: "Switching to \(marker.profileName) did not finish, and your pump did not confirm the new basal rates. It may have the old or the new ones."
                )
            } else if !marker.settingsWritten {
                stage = String(
                    localized: "Switching to \(marker.profileName) did not finish. Your pump has the new basal rates but Trio may still be using the old therapy settings."
                )
            } else {
                stage = String(
                    localized: "Switching to \(marker.profileName) did not finish. The new basal rates and therapy settings are in place, but the algorithm settings may not be."
                )
            }
            let limits = marker.pumpLimitsWritten == true
                ?
                String(
                    localized: "Insulin duration, maximum bolus and maximum basal were already changed to the profile's values."
                )
                : ""
            let check = marker.pumpWriteConfirmed
                ? String(
                    localized: "A running override or temporary target may have been ended. Check your settings before dosing."
                )
                : String(localized: "Check your settings before dosing.")
            return [stage, limits, check].filter { !$0.isEmpty }.joined(separator: " ")
        }

        @ViewBuilder private var switchSheet: some View {
            NavigationView {
                Form {
                    if !state.pendingBlocks.isEmpty {
                        Section(header: Text("Cannot Switch Now")) {
                            ForEach(state.pendingBlocks, id: \.self) { block in
                                Text(block.errorDescription ?? "").foregroundStyle(.red)
                            }
                        }.listRowBackground(Color.chart)
                    } else {
                        if let preview = state.pendingChanges, preview.therapyChanges.isEmpty,
                           preview.pumpChanges.isEmpty, preview.preferenceChanges.isEmpty
                        {
                            Section(header: Text("This Will Change")) {
                                Text("Nothing — this profile matches your current settings.")
                                    .foregroundStyle(.secondary)
                            }.listRowBackground(Color.chart)
                        }

                        if let preview = state.pendingChanges, !preview.therapyChanges.isEmpty {
                            Section(header: Text("Therapy Settings")) {
                                ForEach(preview.therapyChanges) { change in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(change.label).font(.headline)
                                        Text(change.from).font(.footnote).foregroundStyle(.secondary)
                                        Text(change.to).font(.footnote)
                                    }
                                }
                            }.listRowBackground(Color.chart)
                        }

                        if let preview = state.pendingChanges, !preview.pumpChanges.isEmpty {
                            Section(header: Text("Dosing Limits")) {
                                ForEach(preview.pumpChanges) { change in
                                    HStack {
                                        Text(change.label)
                                        Spacer()
                                        Text("\(change.from) → \(change.to)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }.listRowBackground(Color.chart)
                        }

                        if let preview = state.pendingChanges, !preview.preferenceChanges.isEmpty {
                            Section(header: Text("Algorithm Settings")) {
                                ForEach(preview.preferenceChanges) { change in
                                    HStack {
                                        Text(change.label)
                                        Spacer()
                                        Text("\(change.from) → \(change.to)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }.listRowBackground(Color.chart)
                        }

                        Section(header: Text("Also")) {
                            Text("Any running override or temporary target will be cancelled.")
                            if let rate = state.pendingTempBasal {
                                Text(
                                    "A temporary basal of \(rate) U/hr is running. Switching cancels it, and Trio runs a loop straight after to set a new one with the new settings."
                                )
                                .foregroundStyle(.orange)
                            }
                            if let marker = state.interrupted {
                                Text(
                                    "The last switch, to \(marker.profileName), did not finish. This switch rewrites your pump's basal schedule."
                                )
                                .foregroundStyle(.orange)
                            }
                            if state.dosingMode != .closed {
                                Text("Trio is in \(state.dosingMode.displayName). \(state.dosingMode.miniHint)")
                                    .foregroundStyle(.orange)
                            }
                            if state.pendingChanges?.convertedFromMmol == true {
                                Text("This profile's values are in mmol/L and were converted to mg/dL.")
                            }
                            if state.pendingChanges?.carriesPumpSettings == false {
                                Text(
                                    "This profile was saved without insulin duration, maximum bolus and maximum basal, so those stay as they are."
                                )
                                .foregroundStyle(.orange)
                            }
                            if state.pendingChanges?.therapyOnly == true {
                                Text("This profile has no saved algorithm settings, so only your therapy schedules change.")
                                    .foregroundStyle(.orange)
                            }
                            if state.pendingChanges?.hasTargetRange == true {
                                Text("This profile has a target range. Trio uses a single target and will apply the lower value.")
                                    .foregroundStyle(.orange)
                            }
                        }.listRowBackground(Color.chart)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle(state.pendingSwitch?.name ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { state.pendingSwitch = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Switch") { Task { await state.confirmSwitch() } }
                            .disabled(!state.pendingBlocks.isEmpty || state.switchInProgress)
                    }
                }
            }
        }

        private var saveSheet: some View {
            NavigationView {
                Form {
                    Section(
                        header: Text("Profile Name"),
                        footer: Text(
                            state.newProfileNameIsTaken
                                ? "A profile with this name already exists and will be replaced with your current settings."
                                : "Saves your current therapy settings and algorithm settings to Nightscout."
                        )
                    ) {
                        TextField("Name", text: $state.newProfileName)
                            .autocorrectionDisabled()
                    }.listRowBackground(Color.chart)
                }
                .scrollContentBackground(.hidden)
                .background(appState.trioBackgroundColor(for: colorScheme))
                .navigationTitle("Save Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { state.showSaveSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(state.newProfileNameIsTaken ? "Replace" : "Save") {
                            Task { await state.saveCurrentSettings(as: state.newProfileName) }
                        }
                        .disabled(!state.canSaveNewProfile)
                    }
                }
            }
        }
    }
}
