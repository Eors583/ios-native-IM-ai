import PhotosUI
import SwiftUI
import UIKit

struct ProfileView: View {
    @EnvironmentObject private var app: AppModel
    @State private var isEditing = false
    @State private var draft = UserProfile()

    @State private var emailError: String? = nil
    @State private var phoneError: String? = nil

    @State private var pickerItem: PhotosPickerItem? = nil

    private let emailRegex = try! Regex("^[A-Za-z0-9+_.-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$")

    var body: some View {
        NavigationStack {
            if isEditing {
                editView
                    .navigationTitle("编辑个人信息")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                isEditing = false
                            } label: { Image(systemName: "chevron.left") }
                        }
                    }
            } else {
                overviewView
                    .navigationTitle("我的")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                draft = app.profile.load()
                                emailError = nil
                                phoneError = nil
                                isEditing = true
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                        }
                    }
            }
        }
        .onAppear {
            app.syncNicknameFromProfile()
        }
    }

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("我的")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        draft = app.profile.load()
                        emailError = nil
                        phoneError = nil
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }

                avatarView(uri: app.profile.profile.avatarUri, size: 96)
                    .frame(maxWidth: .infinity)

                VStack(spacing: 10) {
                    infoRow(label: "用户名", value: app.profile.profile.username.isEmpty ? "未设置" : app.profile.profile.username)
                    infoRow(label: "邮箱", value: app.profile.profile.email.isEmpty ? "未设置" : app.profile.profile.email)
                    infoRow(label: "性别", value: app.profile.profile.gender.isEmpty ? "未设置" : app.profile.profile.gender)
                    infoRow(label: "电话", value: app.profile.profile.phone.isEmpty ? "未设置" : app.profile.profile.phone)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }

    private var editView: some View {
        ScrollView {
            VStack(spacing: 14) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VStack(spacing: 8) {
                        avatarView(uri: draft.avatarUri, size: 96)
                        Text("点击头像可更换")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            // Persist as a local file under Application Support to avoid Photos permission coupling.
                            let url = saveAvatarDataToDisk(data)
                            await MainActor.run { draft.avatarUri = url?.path ?? "" }
                        }
                    }
                }

                Group {
                    TextField("用户名", text: $draft.username)
                        .textFieldStyle(.roundedBorder)

                    TextField("邮箱", text: $draft.email)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.emailAddress)
                    if let emailError { errorText(emailError) }

                    Picker("性别", selection: $draft.gender) {
                        Text("男").tag("男")
                        Text("女").tag("女")
                        Text("保密").tag("保密")
                    }
                    .pickerStyle(.segmented)

                    TextField("电话", text: $draft.phone)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.phonePad)
                    if let phoneError { errorText(phoneError) }
                }

                Button {
                    if validateAndSave() {
                        isEditing = false
                    }
                } label: {
                    Text("保存")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
    }

    private func validateAndSave() -> Bool {
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = draft.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailErr = validateEmail(email)
        let phoneErr = validatePhone(phone)
        emailError = emailErr
        phoneError = phoneErr
        if emailErr != nil || phoneErr != nil { return false }

        var p = draft
        p.avatarUri = p.avatarUri.trimmingCharacters(in: .whitespacesAndNewlines)
        p.username = p.username.trimmingCharacters(in: .whitespacesAndNewlines)
        p.email = email
        p.gender = p.gender.trimmingCharacters(in: .whitespacesAndNewlines)
        p.phone = phone

        app.profile.save(p)
        app.syncNicknameFromProfile()
        app.errorMessage = "个人信息已保存到本地"
        return true
    }

    private func validateEmail(_ email: String) -> String? {
        if email.isEmpty { return nil }
        return (try? emailRegex.wholeMatch(in: email)) == nil ? "邮箱格式不正确" : nil
    }

    private func validatePhone(_ phone: String) -> String? {
        if phone.isEmpty { return nil }
        let digits = phone.filter { $0.isNumber }
        if !(7...15).contains(digits.count) { return "电话格式不正确" }
        return nil
    }

    private func avatarView(uri: String, size: CGFloat) -> some View {
        let image = loadAvatarImage(uri: uri)
        return Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(uiColor: .tertiarySystemBackground))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: size * 0.8))
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    private func loadAvatarImage(uri: String) -> UIImage? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func saveAvatarDataToDisk(_ data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("avatar-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

