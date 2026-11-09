# Bibliotheken Dritter

Alle Abhängigkeiten des Servers (Rust, direkt und mittelbar, alle Plattformen und Merkmale) und der
App (Dart, nur was die App zur Laufzeit nutzt) mit ihrer Lizenzangabe. Bei Rust steht sie in der
Paketbeschreibung; Dart-Pakete haben dort keine, die Angabe ist aus ihrem Lizenztext abgelesen.
Bei Doppellizenzen (`A OR B`) wird die Apache-2.0-verträgliche Variante genutzt.
Die vollständigen Lizenztexte stehen in `THIRD_PARTY_LICENSES.txt`. Beide Dateien erzeugt
`tools/third-party.py`.

## Server (Rust)

| Crate | Version | Lizenz |
|---|---|---|
| ahash | 0.8.12 | MIT OR Apache-2.0 |
| aho-corasick | 1.1.5 | Unlicense OR MIT |
| ammonia | 4.2.4 | MIT OR Apache-2.0 |
| android_system_properties | 0.1.6 | MIT OR Apache-2.0 |
| anyhow | 1.0.104 | MIT OR Apache-2.0 |
| argon2 | 0.5.3 | MIT OR Apache-2.0 |
| atomic-waker | 1.1.2 | Apache-2.0 OR MIT |
| autocfg | 1.5.1 | Apache-2.0 OR MIT |
| axum | 0.8.9 | MIT |
| axum-core | 0.5.6 | MIT |
| base32 | 0.5.1 | MIT OR Apache-2.0 |
| base64 | 0.22.1 | MIT OR Apache-2.0 |
| base64 | 0.23.1 | MIT OR Apache-2.0 |
| base64ct | 1.8.3 | Apache-2.0 OR MIT |
| bitflags | 2.13.2 | MIT OR Apache-2.0 |
| blake2 | 0.10.6 | MIT OR Apache-2.0 |
| block-buffer | 0.10.4 | MIT OR Apache-2.0 |
| bumpalo | 3.20.3 | MIT OR Apache-2.0 |
| bytes | 1.12.1 | MIT |
| cc | 1.10.0 | MIT OR Apache-2.0 |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 |
| cfg_aliases | 0.2.2 | MIT |
| chacha20 | 0.10.2 | MIT OR Apache-2.0 |
| chrono | 0.4.45 | MIT OR Apache-2.0 |
| constant_time_eq | 0.3.1 | CC0-1.0 OR MIT-0 OR Apache-2.0 |
| core-foundation-sys | 0.8.7 | MIT OR Apache-2.0 |
| core_detect | 1.0.0 | MIT/Apache-2.0 |
| cpufeatures | 0.2.17 | MIT OR Apache-2.0 |
| cpufeatures | 0.3.1 | MIT OR Apache-2.0 |
| crypto-common | 0.1.7 | MIT OR Apache-2.0 |
| cssparser | 0.38.0 | MPL-2.0 |
| digest | 0.10.7 | MIT OR Apache-2.0 |
| displaydoc | 0.2.7 | MIT OR Apache-2.0 |
| dtoa | 1.0.11 | MIT OR Apache-2.0 |
| dtoa-short | 0.3.5 | MPL-2.0 |
| encoding_rs | 0.8.44 | (Apache-2.0 OR MIT) AND BSD-3-Clause |
| equivalent | 1.0.3 | Apache-2.0 OR MIT |
| errno | 0.3.14 | MIT OR Apache-2.0 |
| fallible-iterator | 0.3.0 | MIT/Apache-2.0 |
| fallible-streaming-iterator | 0.1.9 | MIT/Apache-2.0 |
| fastrand | 2.5.0 | Apache-2.0 OR MIT |
| find-msvc-tools | 0.1.15 | MIT OR Apache-2.0 |
| form_urlencoded | 1.2.2 | MIT OR Apache-2.0 |
| futures-channel | 0.3.34 | MIT OR Apache-2.0 |
| futures-core | 0.3.34 | MIT OR Apache-2.0 |
| futures-io | 0.3.34 | MIT OR Apache-2.0 |
| futures-macro | 0.3.34 | MIT OR Apache-2.0 |
| futures-sink | 0.3.34 | MIT OR Apache-2.0 |
| futures-task | 0.3.34 | MIT OR Apache-2.0 |
| futures-util | 0.3.34 | MIT OR Apache-2.0 |
| generic-array | 0.14.7 | MIT |
| getrandom | 0.2.17 | MIT OR Apache-2.0 |
| getrandom | 0.4.3 | MIT OR Apache-2.0 |
| hashbrown | 0.14.5 | MIT OR Apache-2.0 |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 |
| hashlink | 0.9.1 | MIT OR Apache-2.0 |
| hmac | 0.12.1 | MIT OR Apache-2.0 |
| html5ever | 0.40.1 | MIT OR Apache-2.0 |
| http | 1.5.0 | MIT OR Apache-2.0 |
| http-body | 1.1.0 | MIT |
| http-body-util | 0.1.5 | MIT |
| http-range-header | 0.4.2 | MIT |
| httparse | 1.10.1 | MIT OR Apache-2.0 |
| httpdate | 1.0.3 | MIT OR Apache-2.0 |
| hyper | 1.12.0 | MIT |
| hyper-rustls | 0.27.10 | Apache-2.0 OR ISC OR MIT |
| hyper-util | 0.1.21 | MIT |
| iana-time-zone | 0.1.65 | MIT OR Apache-2.0 |
| iana-time-zone-haiku | 0.1.2 | MIT OR Apache-2.0 |
| icu_collections | 2.4.0 | Unicode-3.0 |
| icu_locale_core | 2.4.0 | Unicode-3.0 |
| icu_normalizer | 2.4.0 | Unicode-3.0 |
| icu_normalizer_data | 2.4.0 | Unicode-3.0 |
| icu_properties | 2.4.0 | Unicode-3.0 |
| icu_properties_data | 2.4.0 | Unicode-3.0 |
| icu_provider | 2.4.0 | Unicode-3.0 |
| idna | 1.1.0 | MIT OR Apache-2.0 |
| idna_adapter | 1.2.2 | Apache-2.0 OR MIT |
| indexmap | 2.14.2 | Apache-2.0 OR MIT |
| ipnet | 2.12.2 | MIT OR Apache-2.0 |
| itoa | 1.0.18 | MIT OR Apache-2.0 |
| js-sys | 0.3.107 | MIT OR Apache-2.0 |
| lazy_static | 1.5.1 | MIT OR Apache-2.0 |
| libc | 0.2.191 | MIT OR Apache-2.0 |
| libsqlite3-sys | 0.30.1 | MIT |
| litemap | 0.8.3 | Unicode-3.0 |
| lock_api | 0.4.14 | MIT OR Apache-2.0 |
| log | 0.4.34 | MIT OR Apache-2.0 |
| lru-slab | 0.1.3 | MIT OR Apache-2.0 OR Zlib |
| maplit | 1.0.2 | MIT/Apache-2.0 |
| markup5ever | 0.40.0 | MIT OR Apache-2.0 |
| matchers | 0.2.0 | MIT |
| matchit | 0.8.4 | MIT AND BSD-3-Clause |
| memchr | 2.8.3 | Unlicense OR MIT |
| mime | 0.3.17 | MIT OR Apache-2.0 |
| mime_guess | 2.0.5 | MIT |
| mio | 1.2.4 | MIT |
| multiversion_no_op | 1.0.0 | Apache-2.0 OR MIT |
| new_debug_unreachable | 1.0.6 | MIT |
| nu-ansi-term | 0.50.3 | MIT |
| num-traits | 0.2.19 | MIT OR Apache-2.0 |
| once_cell | 1.21.4 | MIT OR Apache-2.0 |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 |
| password-hash | 0.5.0 | MIT OR Apache-2.0 |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 |
| phf | 0.14.0 | MIT |
| phf_codegen | 0.14.0 | MIT |
| phf_generator | 0.14.0 | MIT |
| phf_shared | 0.14.0 | MIT |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT |
| pkg-config | 0.3.34 | MIT OR Apache-2.0 |
| potential_utf | 0.1.6 | Unicode-3.0 |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 |
| precomputed-hash | 0.1.1 | MIT |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 |
| pulldown-cmark | 0.13.6 | MIT |
| pulldown-cmark-escape | 0.11.0 | MIT |
| quick-xml | 0.41.0 | MIT |
| quinn | 0.11.12 | MIT OR Apache-2.0 |
| quinn-proto | 0.11.19 | MIT OR Apache-2.0 |
| quinn-udp | 0.5.16 | MIT OR Apache-2.0 |
| quote | 1.0.47 | MIT OR Apache-2.0 |
| r-efi | 6.0.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later |
| rand | 0.10.3 | MIT OR Apache-2.0 |
| rand | 0.8.8 | MIT OR Apache-2.0 |
| rand_chacha | 0.3.1 | MIT OR Apache-2.0 |
| rand_core | 0.10.1 | MIT OR Apache-2.0 |
| rand_core | 0.6.4 | MIT OR Apache-2.0 |
| rand_pcg | 0.10.2 | MIT OR Apache-2.0 |
| redox_syscall | 0.5.18 | MIT |
| regex-automata | 0.4.18 | MIT OR Apache-2.0 |
| regex-syntax | 0.8.11 | MIT OR Apache-2.0 |
| reqwest | 0.12.28 | MIT OR Apache-2.0 |
| ring | 0.17.14 | Apache-2.0 AND ISC |
| rss | 2.1.2 | MIT/Apache-2.0 |
| rusqlite | 0.32.1 | MIT |
| rustc-hash | 2.1.3 | Apache-2.0 OR MIT |
| rustls | 0.23.46 | Apache-2.0 OR ISC OR MIT |
| rustls-pki-types | 1.15.1 | MIT OR Apache-2.0 |
| rustls-webpki | 0.103.16 | ISC |
| rustversion | 1.0.23 | MIT OR Apache-2.0 |
| ryu | 1.0.23 | Apache-2.0 OR BSL-1.0 |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 |
| serde | 1.0.229 | MIT OR Apache-2.0 |
| serde_core | 1.0.229 | MIT OR Apache-2.0 |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 |
| serde_json | 1.0.154 | MIT OR Apache-2.0 |
| serde_path_to_error | 0.1.20 | MIT OR Apache-2.0 |
| serde_spanned | 0.6.9 | MIT OR Apache-2.0 |
| serde_urlencoded | 0.7.1 | MIT/Apache-2.0 |
| sha1 | 0.10.7 | MIT OR Apache-2.0 |
| sha2 | 0.10.9 | MIT OR Apache-2.0 |
| sharded-slab | 0.1.7 | MIT |
| shlex | 2.0.1 | MIT OR Apache-2.0 |
| signal-hook-registry | 1.4.8 | MIT OR Apache-2.0 |
| simdutf8 | 0.1.5 | MIT OR Apache-2.0 |
| siphasher | 1.0.4 | MIT OR Apache-2.0 |
| slab | 0.4.12 | MIT |
| smallvec | 1.16.4 | MIT OR Apache-2.0 |
| socket2 | 0.6.5 | MIT OR Apache-2.0 |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 |
| string_cache | 0.11.0 | MIT OR Apache-2.0 |
| string_cache_codegen | 0.11.2 | MIT OR Apache-2.0 |
| subtle | 2.6.1 | BSD-3-Clause |
| syn | 2.0.119 | MIT OR Apache-2.0 |
| syn | 3.0.9 | MIT OR Apache-2.0 |
| sync_wrapper | 1.0.2 | Apache-2.0 |
| synstructure | 0.14.0 | MIT |
| tendril | 0.5.1 | MIT OR Apache-2.0 |
| thiserror | 2.0.21 | MIT OR Apache-2.0 |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 |
| thread_local | 1.1.10 | MIT OR Apache-2.0 |
| tinystr | 0.8.5 | Unicode-3.0 |
| tinyvec | 1.13.3 | Zlib OR Apache-2.0 OR MIT |
| tokio | 1.54.1 | MIT |
| tokio-macros | 2.7.2 | MIT |
| tokio-rustls | 0.26.6 | MIT OR Apache-2.0 |
| tokio-util | 0.7.20 | MIT |
| toml | 0.8.23 | MIT OR Apache-2.0 |
| toml_datetime | 0.6.11 | MIT OR Apache-2.0 |
| toml_edit | 0.22.27 | MIT OR Apache-2.0 |
| toml_write | 0.1.2 | MIT OR Apache-2.0 |
| totp-rs | 5.7.2 | MIT |
| tower | 0.5.3 | MIT |
| tower-http | 0.6.11 | MIT |
| tower-layer | 0.3.3 | MIT |
| tower-service | 0.3.3 | MIT |
| tracing | 0.1.44 | MIT |
| tracing-attributes | 0.1.31 | MIT |
| tracing-core | 0.1.36 | MIT |
| tracing-log | 0.2.0 | MIT |
| tracing-subscriber | 0.3.23 | MIT |
| try-lock | 0.2.5 | MIT |
| typenum | 1.20.1 | MIT OR Apache-2.0 |
| unicase | 2.10.0 | MIT OR Apache-2.0 |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| untrusted | 0.9.0 | ISC |
| url | 2.5.8 | MIT OR Apache-2.0 |
| urlencoding | 2.1.3 | MIT |
| utf8_iter | 1.1.0 | Apache-2.0 OR MIT |
| utf_types | 1.0.0 | Apache-2.0 OR MIT |
| valuable | 0.1.1 | MIT |
| vcpkg | 0.2.15 | MIT/Apache-2.0 |
| version_check | 0.9.5 | MIT/Apache-2.0 |
| want | 0.3.2 | MIT |
| wasi | 0.11.1+wasi-snapshot-preview1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| wasm-bindgen | 0.2.130 | MIT OR Apache-2.0 |
| wasm-bindgen-futures | 0.4.80 | MIT OR Apache-2.0 |
| wasm-bindgen-macro | 0.2.130 | MIT OR Apache-2.0 |
| wasm-bindgen-macro-support | 0.2.130 | MIT OR Apache-2.0 |
| wasm-bindgen-shared | 0.2.130 | MIT OR Apache-2.0 |
| wasm-streams | 0.4.2 | MIT OR Apache-2.0 |
| web-sys | 0.3.107 | MIT OR Apache-2.0 |
| web-time | 1.1.0 | MIT OR Apache-2.0 |
| web_atoms | 0.3.0 | MIT OR Apache-2.0 |
| webpki-roots | 1.0.11 | CDLA-Permissive-2.0 |
| windows-core | 0.62.2 | MIT OR Apache-2.0 |
| windows-implement | 0.60.2 | MIT OR Apache-2.0 |
| windows-interface | 0.59.3 | MIT OR Apache-2.0 |
| windows-link | 0.2.1 | MIT OR Apache-2.0 |
| windows-result | 0.4.1 | MIT OR Apache-2.0 |
| windows-strings | 0.5.1 | MIT OR Apache-2.0 |
| windows-sys | 0.52.0 | MIT OR Apache-2.0 |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 |
| windows-targets | 0.52.6 | MIT OR Apache-2.0 |
| windows_aarch64_gnullvm | 0.52.6 | MIT OR Apache-2.0 |
| windows_aarch64_msvc | 0.52.6 | MIT OR Apache-2.0 |
| windows_i686_gnu | 0.52.6 | MIT OR Apache-2.0 |
| windows_i686_gnullvm | 0.52.6 | MIT OR Apache-2.0 |
| windows_i686_msvc | 0.52.6 | MIT OR Apache-2.0 |
| windows_x86_64_gnu | 0.52.6 | MIT OR Apache-2.0 |
| windows_x86_64_gnullvm | 0.52.6 | MIT OR Apache-2.0 |
| windows_x86_64_msvc | 0.52.6 | MIT OR Apache-2.0 |
| winnow | 0.7.15 | MIT |
| writeable | 0.6.4 | Unicode-3.0 |
| yoke | 0.8.4 | Unicode-3.0 |
| yoke-derive | 0.8.4 | Unicode-3.0 |
| zerocopy | 0.8.63 | BSD-2-Clause OR Apache-2.0 OR MIT |
| zerocopy-derive | 0.8.63 | BSD-2-Clause OR Apache-2.0 OR MIT |
| zerofrom | 0.1.8 | Unicode-3.0 |
| zerofrom-derive | 0.1.8 | Unicode-3.0 |
| zeroize | 1.9.1 | Apache-2.0 OR MIT |
| zerotrie | 0.2.5 | Unicode-3.0 |
| zerovec | 0.11.9 | Unicode-3.0 |
| zerovec-derive | 0.11.7 | Unicode-3.0 |
| zmij | 1.0.23 | MIT |

## Apps (Dart)

| Paket | Version | Lizenz |
|---|---|---|
| android_file_picker | 2.1.2 | MIT |
| archive | 4.5.2 | MIT |
| args | 2.7.0 | BSD-3-Clause |
| async | 2.13.1 | BSD-3-Clause |
| audio_service | 0.18.19 | MIT |
| audio_service_platform_interface | 0.1.3 | MIT |
| audio_service_web | 0.1.4 | MIT |
| audio_session | 0.2.4 | MIT |
| characters | 1.4.1 | BSD-3-Clause |
| clock | 1.1.3 | Apache-2.0 |
| code_assets | 1.2.1 | BSD-3-Clause |
| collection | 1.19.1 | BSD-3-Clause |
| cross_file | 0.3.5+5 | BSD-3-Clause |
| crypto | 3.0.8 | BSD-3-Clause |
| csslib | 1.0.2 | BSD-3-Clause |
| cupertino_icons | 1.0.9 | MIT |
| dbus | 0.8.0 | MPL-2.0 |
| ffi | 2.2.0 | BSD-3-Clause |
| ffi_leak_tracker | 0.1.2 | BSD-3-Clause |
| file | 7.0.1 | BSD-3-Clause |
| file_picker | 13.3.0 | MIT |
| file_picker_darwin | 2.4.0 | MIT |
| file_picker_linux | 2.0.2 | MIT |
| file_picker_platform_interface | 4.2.0 | MIT |
| file_picker_web | 4.2.0 | MIT |
| fixnum | 1.1.1 | BSD-3-Clause |
| flutter_cache_manager | 3.4.6 | MIT |
| flutter_secure_storage | 11.2.0 | BSD-3-Clause |
| flutter_secure_storage_darwin | 0.4.3 | BSD-3-Clause |
| flutter_secure_storage_linux | 3.0.3 | BSD-3-Clause |
| flutter_secure_storage_platform_interface | 2.1.1 | BSD-3-Clause |
| flutter_secure_storage_web | 2.1.1 | BSD-3-Clause |
| flutter_secure_storage_windows | 4.2.2 | BSD-3-Clause |
| hooks | 2.0.2 | BSD-3-Clause |
| html | 0.15.7 | MIT |
| http | 1.6.0 | BSD-3-Clause |
| http_parser | 4.1.2 | BSD-3-Clause |
| image | 4.12.0 | MIT |
| jni | 1.1.1 | BSD-3-Clause |
| jni_flutter | 1.0.4+1 | BSD-3-Clause |
| jni_util | 1.0.0 | BSD-3-Clause |
| js | 0.7.2 | BSD-3-Clause |
| json_annotation | 4.12.0 | BSD-3-Clause |
| just_audio | 0.10.6 (angepasst) | MIT, Apache-2.0 |
| just_audio_media_kit | 2.1.0 (angepasst) | Unlicense |
| just_audio_platform_interface | 4.6.0 | MIT |
| just_audio_web | 0.4.16 | MIT |
| logging | 1.3.0 | BSD-3-Clause |
| material_color_utilities | 0.13.0 | Apache-2.0 |
| media_kit | 1.2.6 | MIT |
| media_kit_libs_linux | 1.2.1 | MIT |
| media_kit_libs_windows_audio | 1.0.9 | MIT |
| meta | 1.18.3 | BSD-3-Clause |
| objective_c | 9.5.0 | BSD-3-Clause |
| package_config | 3.0.0 | BSD-3-Clause |
| package_info_plus | 10.2.2 | BSD-3-Clause |
| package_info_plus_platform_interface | 4.1.0 | BSD-3-Clause |
| path | 1.9.1 | BSD-3-Clause |
| path_provider | 2.1.6 | BSD-3-Clause |
| path_provider_android | 2.3.1 | BSD-3-Clause |
| path_provider_foundation | 2.6.0 | BSD-3-Clause |
| path_provider_linux | 2.2.2 | BSD-3-Clause |
| path_provider_platform_interface | 2.1.3 | BSD-3-Clause |
| path_provider_windows | 2.3.0 | BSD-3-Clause |
| petitparser | 7.0.2 | MIT |
| platform | 3.2.0 | BSD-3-Clause |
| plugin_platform_interface | 2.1.8 | BSD-3-Clause |
| posix | 6.5.4 | MIT |
| pub_semver | 2.2.1 | BSD-3-Clause |
| record_use | 0.6.0 | BSD-3-Clause |
| rxdart | 0.28.0 | Apache-2.0 |
| safe_local_storage | 2.0.7 | MIT |
| screen_retriever | 0.2.2 | MIT |
| screen_retriever_linux | 0.2.2 | MIT |
| screen_retriever_macos | 0.2.2 | MIT |
| screen_retriever_platform_interface | 0.2.2 | MIT |
| screen_retriever_windows | 0.2.2 | MIT |
| source_span | 1.10.2 | BSD-3-Clause |
| sqflite | 2.4.5 | BSD-2-Clause |
| sqflite_android | 2.4.5 | BSD-2-Clause |
| sqflite_common | 2.5.14 | BSD-2-Clause |
| sqflite_darwin | 2.4.4+1 | BSD-2-Clause |
| sqflite_platform_interface | 2.4.3 | BSD-2-Clause |
| string_scanner | 1.4.1 | BSD-3-Clause |
| synchronized | 3.5.0 | MIT |
| term_glyph | 1.2.2 | BSD-3-Clause |
| typed_data | 1.4.0 | BSD-3-Clause |
| universal_platform | 1.1.0 | MIT |
| uri_parser | 3.0.2 | MIT |
| url_launcher | 6.3.3 | BSD-3-Clause |
| url_launcher_android | 6.3.33 | BSD-3-Clause |
| url_launcher_ios | 6.4.2 | BSD-3-Clause |
| url_launcher_linux | 3.2.3 | BSD-3-Clause |
| url_launcher_macos | 3.2.6 | BSD-3-Clause |
| url_launcher_platform_interface | 2.3.2 | BSD-3-Clause |
| url_launcher_web | 2.4.3 | BSD-3-Clause |
| url_launcher_windows | 3.1.6 | BSD-3-Clause |
| uuid | 4.6.0 | MIT |
| vector_math | 2.4.0 | BSD-3-Clause |
| volume_controller | 3.7.1 | MIT |
| web | 1.1.2 | BSD-3-Clause |
| win32 | 6.4.0 | BSD-3-Clause |
| window_manager | 0.5.2 | MIT |
| windows_file_picker | 2.0.1 | MIT |
| xdg_directories | 1.1.0 | BSD-3-Clause |
| xml | 7.0.1 | MIT |
| yaml | 3.1.4 | MIT |

Dazu kommt das [Flutter SDK](https://flutter.dev) (BSD-3-Clause) mit seiner Engine; deren
Bestandteile und Lizenzen zeigt die App unter **Einstellungen → Über audiojoe → Lizenzen Dritter**.

## Im Server eingebaut (statisch gelinkt)

| Bibliothek | Lizenz | Verwendung |
|---|---|---|
| SQLite (über `libsqlite3-sys`, Merkmal `bundled`) | Public Domain | Datenbank |
| ring (Kryptografie für TLS über rustls) | siehe Tabelle oben | HTTPS zu Quellen und Verzeichnissen |

## Android: eingebaute Bibliotheken

Über die Dart-Pakete `just_audio` und `audio_service` kommen aus Googles Maven-Verzeichnis:

| Bibliothek | Lizenz | Verwendung |
|---|---|---|
| [AndroidX Media3](https://developer.android.com/media/media3) (ExoPlayer) 1.4.1 | Apache-2.0 | Wiedergabe |
| AndroidX Core, AndroidX Media | Apache-2.0 | Mediensitzung, Sperrbildschirm, Benachrichtigung |

## Linux und Windows: Wiedergabe

Die Desktop-App spielt über [media_kit](https://github.com/media-kit/media-kit) mit libmpv ab.

- **Linux:** libmpv kommt vom System (Ubuntu-Paket `libmpv2`) und wird nicht mitgeliefert.
- **Windows:** `media_kit_libs_windows_audio` lädt beim Bauen eine auf Ton beschränkte Fassung von
  libmpv und FFmpeg (`mpv-dev-x86_64-20230924-git-652a1dd`, aus
  [media-kit/libmpv-win32-audio-build](https://github.com/media-kit/libmpv-win32-audio-build)).
  Das Windows-Paket liefert daraus `libmpv-2.dll` mit; die App lädt sie dynamisch.
  - **Lizenz der DLL: LGPL-3.0-or-later.** mpv ist mit `-Dgpl=false` gebaut (LGPL-2.1-or-later),
    FFmpeg mit `--disable-gpl --disable-nonfree --enable-version3` (LGPL-3.0-or-later) und statisch
    in die DLL gelinkt; damit gilt für die DLL als Ganzes LGPL-3.0-or-later. Belegt durch
    `packages/mpv.cmake` und `packages/ffmpeg.cmake` des Bau-Repositorys.
  - **Mitgebaute Bibliotheken** (laut denselben Dateien): unter LGPL fribidi, libplacebo,
    openal-soft, LAME, libsoxr; uchardet (MPL-1.1, GPL-2.0 oder LGPL-2.1 nach Wahl); unter
    freizügigen Lizenzen libass und mujs (ISC), harfbuzz, lcms2, libxml2, libvpl (MIT), libarchive,
    libwebp, libmysofa, Opus, Speex, Vorbis (BSD), libjpeg (IJG), libpng (libpng), bzip2 (bzip2),
    zimg (WTFPL), mbedtls (Apache-2.0). Keine Bibliothek, die nur unter GPL steht.
  - **Quelltext:** die Bauanleitung im Repository
    [media-kit/libmpv-win32-audio-build](https://github.com/media-kit/libmpv-win32-audio-build)
    (Release `2023-09-24`) mit den Quellen von [mpv](https://github.com/mpv-player/mpv) und
    [FFmpeg](https://github.com/FFmpeg/FFmpeg) (Stand `ea3d24bbe3c5`). Die LGPL erlaubt, die DLL
    durch eine eigene Fassung zu ersetzen; sie liegt neben `audiojoe.exe` im Programmordner.

## Web-App

Zur Laufzeit nutzt nur der Autotest (`/testcar/`) ein Paket Dritter:
[qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator) 2.0.4 von Kazuhiko Arase
(MIT) für den QR-Code mit den Ergebnissen. Beim Bauen kommen
[TypeScript](https://www.typescriptlang.org) (Apache-2.0) und [Vite](https://vite.dev) (MIT) zum
Einsatz; Vite fügt dabei einen kleinen eigenen Ladeteil ein (MIT).

## Symbole und Bilder

| Quelle | Lizenz | Hinweis |
|---|---|---|
| [Material Icons](https://fonts.google.com/icons) (in Flutter enthalten) | Apache-2.0 | Symbole der App |
| Logo und App-Symbol (`design/`) | wie das Projekt (Apache-2.0) | eigener Entwurf |
| Symbole der Web-App | wie das Projekt (Apache-2.0) | eigene SVG-Pfade in `clients/web/src/app/ui.ts` |

## Daten

| Quelle | Hinweis |
|---|---|
| [Radio Browser](https://www.radio-browser.info) | Freies Verzeichnis der Internetradio-Sender (Namen, Adressen, Logos). audiojoe fragt es bei der Sendersuche und meldet jedes Abspielen eines Senders als Klick, wie es das Verzeichnis erbittet. Die Streams und Logos kommen von den Sendern. |
| [fyyd](https://fyyd.de) | Podcast-Verzeichnis für die Podcast-Suche. |
| Podcast-Feeds | Titel, Beschreibungen, Bilder, Kapitel und Folgen kommen von den Anbietern der abonnierten Podcasts. |
| [MusicBrainz](https://musicbrainz.org) | Nur wenn eingeschaltet: Labels von Alben, deren Dateien keines nennen. Diese Daten gehören zum Kerndatenbestand von MusicBrainz und stehen unter [CC0](https://musicbrainz.org/doc/About/Data_License). |
| Medien und Cover | Nicht mitgeliefert; stammen aus den Quellen, die der Nutzer selbst einträgt (Jellyfin, Plex, Emby, Audiobookshelf). |
