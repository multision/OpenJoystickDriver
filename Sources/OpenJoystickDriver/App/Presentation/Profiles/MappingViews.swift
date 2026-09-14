#if canImport(SwiftUI)

  import AppKit
  import Foundation
  import OpenJoystickDriverKit
  import SwiftUI
  import UniformTypeIdentifiers

  struct ProfilesView: View {
    @ObservedObject
    var viewModel: RuntimeViewModel
    @ObservedObject
    var navigation: SettingsNavigationModel
    @ObservedObject
    var screen: ProfilesViewModel

    var selectedProfileID: UUID? {
      get { screen.selectedProfileID }
      nonmutating set { screen.selectedProfileID = newValue }
    }
    var isCreatingProfile: Bool {
      get { screen.isCreatingProfile }
      nonmutating set { screen.isCreatingProfile = newValue }
    }
    var profileEditorTransition: ProfileEditorTransitionState {
      get { screen.editorTransition }
      nonmutating set { screen.editorTransition = newValue }
    }
    var activeAlert: ProfilesAlert? {
      get { screen.activeAlert }
      nonmutating set { screen.activeAlert = newValue }
    }
    var profileActionError: String? {
      get { screen.profileActionError }
      nonmutating set { screen.profileActionError = newValue }
    }
    var observedDiscardGeneration: Int {
      get { screen.observedDiscardGeneration }
      nonmutating set { screen.observedDiscardGeneration = newValue }
    }
    var lastKnownSnapshot: ApplicationServiceRemappingSnapshotPayload? {
      get { screen.lastKnownSnapshot }
      nonmutating set { screen.lastKnownSnapshot = newValue }
    }
    var preservedEditorProfile: RemappingProfile? {
      get { screen.preservedEditorProfile }
      nonmutating set { screen.preservedEditorProfile = newValue }
    }
    var profileEditorGeneration: Int {
      get { screen.editorGeneration }
      nonmutating set { screen.editorGeneration = newValue }
    }
    var pairingProfile: RemappingProfile? {
      get { screen.pairingProfile }
      nonmutating set { screen.pairingProfile = newValue }
    }
    var selectedEditorSection: ProfileEditorSection {
      get { screen.selectedEditorSection }
      nonmutating set { screen.selectedEditorSection = newValue }
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        if let profileActionError {
          ProfileActionErrorBanner(message: profileActionError) { self.profileActionError = nil }
        }
        GeometryReader { proxy in
          if proxy.size.width < 620 {
            VStack(spacing: 0) {
              profileList.frame(height: min(200, proxy.size.height * 0.34))
              Divider()
              profileDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          } else {
            HStack(spacing: 0) {
              profileList.frame(width: profileListWidth(for: proxy.size.width)).frame(
                maxHeight: .infinity,
                alignment: .topLeading
              )
              Divider()
              profileDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
      }.sheet(isPresented: $screen.isCreatingProfile) {
        ProfileNameSheet(
          title: OJDLocalized.string("profiles.new", fallback: "New profile"),
          initialName: OJDLocalized.string("profiles.defaultName", fallback: "My controller"),
          devices: connectedDevices
        ) { name, device, scope in createProfile(named: name, for: device, scope: scope) }
      }.sheet(item: $screen.pairingProfile) { profile in
        ProfileJoyConPairSheet(profile: profile, devices: connectedDevices) { left, right in
          Task { @MainActor in
            profileActionError = await viewModel.pairRemappingJoyCons(
              left: left,
              right: right,
              profileID: profile.id
            )
          }
        }
      }.alert(item: $screen.activeAlert) { alert in
        switch alert {
        case .delete(let id):
          Alert(
            title: Text(OJDLocalized.string("profiles.deleteTitle", fallback: "Delete profile?")),
            message: Text(
              OJDLocalized.string(
                "profiles.deleteMessage",
                fallback: "This removes the profile from OpenJoystickDriver."
              )
            ),
            primaryButton: .destructive(
              Text(OJDLocalized.string("common.delete", fallback: "Delete"))
            ) { deleteProfile(id) },
            secondaryButton: .cancel { activeAlert = nil }
          )
        case .discard:
          Alert(
            title: Text(
              OJDLocalized.string("settings.discardTitle", fallback: "Discard unsaved changes?")
            ),
            message: Text(
              OJDLocalized.string(
                "profiles.discardMessage",
                fallback: "Your changes to this profile have not been saved."
              )
            ),
            primaryButton: .destructive(
              Text(OJDLocalized.string("settings.discardAction", fallback: "Discard Changes"))
            ) {
              guard let action = profileEditorTransition.discardPendingAction() else {
                activeAlert = nil
                return
              }
              setEditorDirty(false)
              activeAlert = nil
              performProfileAction(action)
            },
            secondaryButton: .cancel { cancelPendingProfileAction() }
          )
        }
      }.onAppear {
        if case .available(let snapshot) = viewModel.remappingState { lastKnownSnapshot = snapshot }
        if observedDiscardGeneration != navigation.discardGeneration {
          profileEditorTransition.setDirty(false)
          observedDiscardGeneration = navigation.discardGeneration
        }
        selectFirstProfileIfNeeded()
        navigation.setProfilesEditorDirty(editorHasUnsavedChanges)
        handleProfileMutation(viewModel.mutationState)
      }.onReceive(viewModel.$mutationState) { handleProfileMutation($0) }.onReceive(
        navigation.$discardGeneration
      ) { generation in
        observedDiscardGeneration = generation
        if editorHasUnsavedChanges { setEditorDirty(false) }
      }.onReceive(viewModel.$remappingState) { state in
        if case .available(let snapshot) = state {
          if !editorHasUnsavedChanges, let selectedProfileID,
            lastKnownSnapshot?.profiles.first(where: { $0.id == selectedProfileID })
              != snapshot.profiles.first(where: { $0.id == selectedProfileID })
          {
            profileEditorGeneration += 1
          }
          if editorHasUnsavedChanges, let selectedProfileID,
            !snapshot.profiles.contains(where: { $0.id == selectedProfileID }),
            let previous = lastKnownSnapshot?.profiles.first(where: { $0.id == selectedProfileID })
          {
            preservedEditorProfile = previous
          }
          lastKnownSnapshot = snapshot
          selectFirstProfileIfNeeded()
        }
      }
    }

    var profiles: [RemappingProfile] {
      switch viewModel.remappingState {
      case .available(let snapshot): return snapshot.profiles
      case .loading, .unavailable, .error: return lastKnownSnapshot?.profiles ?? []
      }
    }

    func profileListWidth(for availableWidth: CGFloat) -> CGFloat {
      min(220, max(168, availableWidth * 0.25))
    }

    var selectedProfile: RemappingProfile? {
      if let selectedProfileID {
        if let current = profiles.first(where: { $0.id == selectedProfileID }) { return current }
        if let preservedEditorProfile, preservedEditorProfile.id == selectedProfileID {
          return preservedEditorProfile
        }
      }
      return profiles.first
    }

    var profileList: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(OJDLocalized.string("common.profiles", fallback: "Profiles")).font(.headline)
          Spacer()
          Button(
            action: { isCreatingProfile = true },
            label: {
              OJDSystemSymbol(name: "plus", fallback: "+").ojdAccessibilityLabel(
                OJDLocalized.string("profiles.new", fallback: "New profile")
              ).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            }
          ).buttonStyle(BorderlessButtonStyle()).disabled(isProfileActionBlocked)
          Button(action: importProfile) {
            OJDSystemSymbol(name: "square.and.arrow.down", fallback: "Import")
              .ojdAccessibilityLabel(
                OJDLocalized.string("profiles.import", fallback: "Import profile")
              ).frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
          }.buttonStyle(BorderlessButtonStyle()).disabled(isProfileActionBlocked)
        }.padding(.horizontal, 14).padding(.top, 18)

        switch viewModel.remappingState {
        case .loading:
          LoadingStateView(
            message: OJDLocalized.string("profiles.loading", fallback: "Loading profiles...")
          ).padding(.horizontal, 14)
        case .unavailable(let message), .error(let message):
          VStack(alignment: .leading, spacing: 6) {
            Text(
              OJDLocalized.string("profiles.loadError", fallback: "Profiles could not be loaded.")
            ).font(.caption.weight(.semibold))
            Text(message).font(.caption).foregroundColor(Color(NSColor.secondaryLabelColor))
              .fixedSize(horizontal: false, vertical: true)
            Button(
              OJDLocalized.string("common.tryAgain", fallback: "Try again"),
              action: refreshProfiles
            )
          }.padding(.horizontal, 14)
        case .available: if !profiles.isEmpty { profileListRows }
        }
        Spacer(minLength: 0)
      }.background(Color(NSColor.controlBackgroundColor))
    }

    var profileListRows: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(profiles) { profile in
            Button(
              action: { selectProfile(profile.id) },
              label: {
                HStack(spacing: 8) {
                  OJDListGlyphSlot {
                    OJDSystemSymbol(
                      name: isActive(profile) ? "checkmark.circle.fill" : "circle",
                      fallback: isActive(profile) ? "✓" : "○"
                    ).foregroundColor(Color(NSColor.controlAccentColor))
                  }
                  VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).lineLimit(1)
                    Text(assignmentCountLabel(profile.bindings.count)).font(.caption)
                      .foregroundColor(Color(NSColor.secondaryLabelColor))
                  }
                  Spacer(minLength: 0)
                }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
              }
            ).buttonStyle(ProfileListButtonStyle(selected: selectedProfile?.id == profile.id))
              .ojdAccessibilityLabel(profile.name).ojdAccessibilitySelection(
                selectedProfile?.id == profile.id
              ).ojdAccessibilityValue(profileAccessibilityValue(profile))
          }
        }.padding(.horizontal, 8).disabled(isProfileActionBlocked)
      }
    }

    @ViewBuilder
    var profileDetail: some View {
      if let selectedProfile {
        VStack(alignment: .leading, spacing: 0) {
          refreshStatus
          if selectedProfile.joyConPair != nil { joyConPairControls(selectedProfile) }
          ProfileEditorView(
            profile: selectedProfile,
            editor: screen.editor(
              for: selectedProfile,
              discardGeneration: navigation.discardGeneration
            ),
            viewModel: viewModel,
            isActive: isActive(selectedProfile),
            isEditingBlocked: profileEditorTransition.isEditingBlocked,
            selectedSection: $screen.selectedEditorSection,
            onDelete: { activeAlert = .delete(selectedProfile.id) },
            onExport: { exportProfile($0) },
            onEditingStateChanged: { setEditorDirty($0) },
            onMutationStarted: { beginProfileMutation($0) },
            onMutationResult: { handleProfileMutationResult($0) }
          ).id(
            selectedProfile.id.uuidString + "-\(navigation.discardGeneration)"
              + "-\(profileEditorGeneration)"
          )
        }
      } else {
        switch viewModel.remappingState {
        case .loading:
          LoadingStateView(
            message: OJDLocalized.string("profiles.loading", fallback: "Loading profiles...")
          ).padding(28)
        case .unavailable(let message):
          ServiceFailureStateView(
            title: OJDLocalized.string("profiles.unavailable", fallback: "Profiles unavailable"),
            message: message,
            retry: refreshProfiles
          ).padding(28)
        case .error(let message):
          ServiceFailureStateView(
            title: OJDLocalized.string(
              "profiles.loadError",
              fallback: "Profiles could not be loaded."
            ),
            message: message,
            retry: refreshProfiles
          ).padding(28)
        case .available: noProfilesState.padding(28)
        }
      }
    }

    @ViewBuilder
    func joyConPairControls(_ profile: RemappingProfile) -> some View {
      let sessions = currentSnapshot?.joyConPairs.filter { $0.profileID == profile.id } ?? []
      HStack(spacing: 10) {
        Text(OJDLocalized.string("profiles.joyConPair", fallback: "Paired Joy-Con profile")).font(
          .caption.weight(.semibold)
        )
        if sessions.isEmpty {
          Button(
            OJDLocalized.string("profiles.pairJoyCons", fallback: "Pair connected Joy-Cons...")
          ) { pairingProfile = profile }.disabled(!hasAvailableJoyConPair || isProfileActionBlocked)
        } else {
          Text(OJDLocalized.string("profiles.joyConPairActive", fallback: "Pair active")).font(
            .caption
          ).foregroundColor(Color(NSColor.secondaryLabelColor))
          ForEach(sessions, id: \.sessionID) { session in
            Button(OJDLocalized.string("profiles.unpairJoyCons", fallback: "Unpair")) {
              Task { @MainActor in
                profileActionError = await viewModel.unpairRemappingJoyCons(
                  sessionID: session.sessionID
                )
              }
            }.disabled(isProfileActionBlocked)
          }
        }
        Spacer()
      }.padding(.horizontal, 28).padding(.top, 10)
    }

    var currentSnapshot: ApplicationServiceRemappingSnapshotPayload? {
      if case .available(let snapshot) = viewModel.remappingState { return snapshot }
      return lastKnownSnapshot
    }

    var hasAvailableJoyConPair: Bool {
      connectedDevices.contains { $0.vendorID == 0x057E && $0.productID == 0x2006 }
        && connectedDevices.contains { $0.vendorID == 0x057E && $0.productID == 0x2007 }
    }

    var noProfilesState: some View {
      VStack(alignment: .leading, spacing: 12) {
        EmptyStateView(
          symbol: "plus.circle",
          title: OJDLocalized.string("profiles.none", fallback: "No profiles"),
          message: OJDLocalized.string(
            "profiles.createMessage",
            fallback: "Create a profile to start assigning controls."
          )
        )
        Button(OJDLocalized.string("profiles.create", fallback: "Create profile...")) {
          isCreatingProfile = true
        }.disabled(isProfileActionBlocked)
      }
    }

    func assignmentCountLabel(_ count: Int) -> String {
      OJDLocalized.plural("profiles.assignments", count: count, fallback: "%d assignments")
    }

    func profileAccessibilityValue(_ profile: RemappingProfile) -> String {
      let count = assignmentCountLabel(profile.bindings.count)
      guard isActive(profile) else { return count }
      return OJDLocalized.formatted("profiles.activeAssignmentCount", fallback: "%@, active", count)
    }

    @ViewBuilder
    var refreshStatus: some View {
      switch viewModel.remappingState {
      case .loading:
        HStack(spacing: 8) {
          OJDLoadingIndicator()
          Text(OJDLocalized.string("profiles.refreshing", fallback: "Refreshing profile state..."))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
        }.padding(.horizontal, 28).padding(.top, 14)
      case .unavailable(let message):
        ServiceFailureStateView(
          title: OJDLocalized.string(
            "profiles.stateUnavailable",
            fallback: "Profile state is unavailable"
          ),
          message: OJDLocalized.formatted(
            "profiles.draftPreserved",
            fallback: "Your current draft is preserved. %@",
            message
          ),
          retry: refreshProfiles
        ).padding(.horizontal, 28).padding(.top, 14)
      case .error(let message):
        ServiceFailureStateView(
          title: OJDLocalized.string(
            "profiles.refreshError",
            fallback: "Could not refresh profile state"
          ),
          message: OJDLocalized.formatted(
            "profiles.draftPreserved",
            fallback: "Your current draft is preserved. %@",
            message
          ),
          retry: refreshProfiles
        ).padding(.horizontal, 28).padding(.top, 14)
      case .available: EmptyView()
      }
    }

  }

#endif
