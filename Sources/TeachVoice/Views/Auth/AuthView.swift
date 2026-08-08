import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var auth: AuthManager

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Text("Teach (Voice)")
                    .font(.largeTitle.bold())
                Text("Karteikarten lernen per Stimme")
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    TextField("E-Mail", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                    SecureField("Passwort", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task {
                        if isSignUp {
                            await auth.signUp(email: email, password: password)
                        } else {
                            await auth.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    if auth.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(isSignUp ? "Registrieren" : "Anmelden")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty || password.count < 6 || auth.isLoading)
                .padding(.horizontal)

                Button(isSignUp ? "Ich habe schon ein Konto" : "Neues Konto erstellen") {
                    isSignUp.toggle()
                    auth.errorMessage = nil
                }
                .font(.footnote)

                HStack {
                    VStack { Divider() }
                    Text("oder").font(.caption).foregroundStyle(.secondary)
                    VStack { Divider() }
                }
                .padding(.horizontal)

                VStack(spacing: 6) {
                    Button {
                        auth.continueAsGuest()
                    } label: {
                        Label("Als Gast fortfahren", systemImage: "person.fill.questionmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)

                    Text("Deine Karteikarten werden dann nur lokal auf diesem Gerät gespeichert – ohne Cloud-Backup, ohne Konto.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()
                Spacer()
            }
            .padding()
        }
    }
}
