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
    var selectedRecoveryIssueID: UUID? {
      get { screen.selectedRecoveryIssueID }
      nonmutating set { screen.selectedRecoveryIssueID = newValue }
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
          if WorkspaceListDetailPolicy.layout(for: proxy.size.width) == .stacked {
            VStack(spacing: 0) {
              profileList.frame(
                height: WorkspaceListDetailPolicy.compactListHeight(
                  itemCount: profiles.count + (currentSnapshot?.profileIssues.count ?? 0),
                  availableHeight: proxy.size.height
                )
              )
              Divider()
              profileDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          } else {
            HStack(spacing: 0) {
              profileList.frame(width: WorkspaceListDetailPolicy.listWidth(for: proxy.size.width))
                .frame(maxHeight: .infinity, alignment: .topLeading)
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
        case .deleteDamagedProfile(let issueID):
          Alert(
            title: Text(
              OJDLocalized.string("profiles.damagedProfile", fallback: "Damaged profile")
            ),
            message: Text(
              OJDLocalized.string(
                "profiles.recoveryBackupMessage",
                fallback: "A backup will be created before damaged data is removed."
              )
            ),
            primaryButton: .destructive(
              Text(OJDLocalized.string("common.delete", fallback: "Delete"))
            ) { recoverProfileIssue(issueID, resetLibrary: false) },
            secondaryButton: .cancel { activeAlert = nil }
          )
        case .resetLibrary(let issueID):
          Alert(
            title: Text(
              OJDLocalized.string("profiles.damagedLibrary", fallback: "Profile library")
            ),
            message: Text(
              OJDLocalized.string(
                "profiles.recoveryBackupMessage",
                fallback: "A backup will be created before damaged data is removed."
              )
            ),
            primaryButton: .destructive(
              Text(OJDLocalized.string("profiles.resetLibraryAction", fallback: "Back Up & Reset"))
            ) { recoverProfileIssue(issueID, resetLibrary: true) },
            secondaryButton: .cancel { activeAlert = nil }
          )
        }
      }.onAppear {
        if case .available(let snapshot) = viewModel.remappingState {
          lastKnownSnapshot = snapshot
          screen.reconcileSelection(with: snapshot)
        }
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
          screen.reconcileSelection(with: snapshot)
        }
      }
    }

    var profiles: [RemappingProfile] {
      switch viewModel.remappingState {
      case .available(let snapshot): return snapshot.profiles
      case .loading, .unavailable, .error: return lastKnownSnapshot?.profiles ?? []
      }
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

    var selectedRecoveryIssue: ApplicationServiceRemappingProfileIssue? {
      guard let selectedRecoveryIssueID else { return nil }
      return currentSnapshot?.profileIssues.first { $0.id == selectedRecoveryIssueID }
    }

    var profileList: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(OJDLocalized.string("common.profiles", fallback: "Profiles")).font(.headline)
          Spacer()
          OJDCompactSymbolButton(
            symbolName: "plus",
            label: OJDLocalized.string("profiles.new", fallback: "New profile")
          ) { isCreatingProfile = true }.disabled(isProfileActionBlocked)
          OJDCompactSymbolButton(
            symbolName: "square.and.arrow.down",
            label: OJDLocalized.string("profiles.import", fallback: "Import profile"),
            action: importProfile
          ).disabled(isProfileActionBlocked)
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
        case .available:
          if !profiles.isEmpty || !(currentSnapshot?.profileIssues.isEmpty ?? true) {
            profileListRows
          }
        }
        Spacer(minLength: 0)
      }.background(Color(NSColor.controlBackgroundColor))
    }

    var profileListRows: some View {
      List(selection: profileListSelection) {
        ForEach(profiles) { profile in
          HStack(spacing: 8) {
            OJDListGlyphSlot {
              let semanticState: SemanticState = isActive(profile) ? .active : .inactive
              OJDSystemSymbol(
                name: semanticState.presentation.symbolName,
                fallback: isActive(profile)
                  ? OJDLocalized.string("profiles.active", fallback: "Active")
                  : OJDLocalized.string("profiles.notActive", fallback: "Not active")
              ).foregroundColor(Color(semanticState.presentation.tone.color))
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.name).lineLimit(1)
              Text(assignmentCountLabel(profile.bindings.count)).font(.caption).foregroundColor(
                Color(NSColor.secondaryLabelColor)
              )
            }
            Spacer(minLength: 0)
          }.padding(.vertical, 4).tag(ProfileListSelection.profile(profile.id))
            .ojdAccessibilityLabel(profile.name).ojdAccessibilityValue(
              profileAccessibilityValue(profile)
            )
        }
        ForEach(currentSnapshot?.profileIssues ?? []) { issue in
          HStack(spacing: 8) {
            OJDListGlyphSlot {
              OJDSystemSymbol(
                name: issue.kind == .damagedProfile
                  ? "exclamationmark.triangle.fill" : "xmark.octagon.fill",
                fallback: OJDLocalized.string("common.needsAttention", fallback: "Needs attention")
              ).foregroundColor(
                Color(
                  (issue.kind == .damagedProfile ? SemanticState.attention : .failure).presentation
                    .tone.color
                )
              )
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(
                OJDLocalized.string(
                  issue.kind == .damagedProfile
                    ? "profiles.damagedProfile" : "profiles.damagedLibrary",
                  fallback: issue.kind == .damagedProfile ? "Damaged profile" : "Profile library"
                )
              ).lineLimit(1)
              Text(OJDLocalized.string("common.needsAttention", fallback: "Needs attention")).font(
                .caption
              ).foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            Spacer(minLength: 0)
          }.padding(.vertical, 4).tag(ProfileListSelection.issue(issue.id)).ojdAccessibilityValue(
            profileIssueMessage(issue)
          )
        }
      }.listStyle(SidebarListStyle()).disabled(
        isMutationActive || viewModel.profileRecoveryInFlight
      )
    }

    private var profileListSelection: Binding<ProfileListSelection?> {
      Binding(
        get: {
          if let selectedRecoveryIssueID { return .issue(selectedRecoveryIssueID) }
          return selectedProfileID.map(ProfileListSelection.profile)
        },
        set: { selection in
          switch selection {
          case .profile(let profileID):
            selectedRecoveryIssueID = nil
            selectProfile(profileID)
          case .issue(let issueID): selectedRecoveryIssueID = issueID
          case nil: break
          }
        }
      )
    }

    @ViewBuilder
    var profileDetail: some View {
      if let selectedRecoveryIssue {
        profileRecoveryDetail(selectedRecoveryIssue).padding(28)
      } else if let selectedProfile {
        VStack(alignment: .leading, spacing: 0) {
          refreshStatus
          if selectedProfile.joyConPair != nil { joyConPairControls(selectedProfile) }
          ProfileEditorView(
            profile: selectedProfile,
            capabilities: ProfileCapabilityResolver.resolve(
              profile: selectedProfile,
              connectedDevices: connectedDevices,
              registry: screen.capabilityRegistry
            ) ?? .unsupported,
            editor: screen.editor(
              for: selectedProfile,
              discardGeneration: navigation.discardGeneration
            ),
            viewModel: viewModel,
            isActive: isActive(selectedProfile),
            isEditingBlocked: profileEditorTransition.isEditingBlocked
              || profileLibraryNeedsRecovery,
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

    private func profileRecoveryDetail(
      _ issue: ApplicationServiceRemappingProfileIssue
    ) -> some View {
      VStack(alignment: .leading, spacing: 14) {
        OJDSystemSymbol(
          name: issue.kind == .damagedProfile
            ? "exclamationmark.triangle.fill" : "xmark.octagon.fill",
          fallback: OJDLocalized.string("common.needsAttention", fallback: "Needs attention")
        ).font(.largeTitle).foregroundColor(
          Color(
            (issue.kind == .damagedProfile ? SemanticState.attention : .failure).presentation.tone
              .color
          )
        ).ojdAccessibilityHidden(true)
        Text(
          OJDLocalized.string(
            issue.kind == .damagedProfile ? "profiles.damagedProfile" : "profiles.damagedLibrary",
            fallback: issue.kind == .damagedProfile ? "Damaged profile" : "Profile library"
          )
        ).font(.title.weight(.semibold))
        Text(profileIssueMessage(issue)).foregroundColor(Color(NSColor.secondaryLabelColor))
          .fixedSize(horizontal: false, vertical: true)
        Button(
          OJDLocalized.string(
            issue.kind == .damagedProfile
              ? "profiles.deleteDamagedButton" : "profiles.resetLibraryButton",
            fallback: issue.kind == .damagedProfile
              ? "Delete Damaged Profile..." : "Back Up & Reset Library..."
          )
        ) {
          activeAlert =
            issue.kind == .damagedProfile
            ? .deleteDamagedProfile(issue.id) : .resetLibrary(issue.id)
        }.disabled(viewModel.profileRecoveryInFlight)
        Spacer()
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ojdAccessibilityLabel(
          OJDLocalized.string(
            issue.kind == .damagedProfile ? "profiles.damagedProfile" : "profiles.damagedLibrary",
            fallback: issue.kind == .damagedProfile ? "Damaged profile" : "Profile library"
          )
        ).ojdAccessibilityValue(profileIssueMessage(issue))
    }

    private func profileIssueMessage(_ issue: ApplicationServiceRemappingProfileIssue) -> String {
      OJDLocalized.string(
        issue.kind == .damagedProfile ? "profiles.damagedProfileMessage" : "profiles.loadError",
        fallback: issue.kind == .damagedProfile
          ? "This saved profile could not be read. Delete it to continue using the valid profiles."
          : "Profiles could not be loaded."
      )
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
