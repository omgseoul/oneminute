# OMS Android release and update continuity

Production APKs use one persistent PKCS12 key stored encrypted in Supabase Vault (`oms_android_release_signing`). The key is not stored in this repository or build artifacts.

The android-signing Edge Function verifies GitHub OIDC signatures, issuer, audience, repository and immutable IDs, main branch, exact workflow, event and runner. Only the release job in `build-android-apk.yml` can request signing material. The service-role-only RPC rejects reused token IDs and records the run and commit. Pull request jobs only compile debug builds and cannot request release keys.

The workflow signs two adjacent version codes with the persistent key and runs an emulator test: seed a private preference in the predecessor, install the production APK with `adb install -r`, then verify the preference still exists. Publishing additionally verifies the package ID, certificate and nondecreasing version code against the existing update manifest.

Release `versionCode` is `1000 + GITHUB_RUN_NUMBER`. `versionName` starts at 0.15.0; bump it when naming the next user-facing release. Run the release workflow on main to publish. The verified artifact is `downloads/OMS-latest.apk`; update metadata is `downloads/oms-update.json`.

Previous 0.14.x APKs were signed with different, temporary debug keys. They cannot be replaced by the new release signature without the matching old private key. Users transitioning from those builds need one reinstall. Subsequent release APKs update in place. The website UI continues to update independently.

Back up the Supabase project and Vault secrets. Do not rotate or overwrite the release keystore as a routine build step. Losing it loses update continuity. Google Play distribution must use this same app signing key if preserving APK-to-Play update compatibility.
