# 依存ライセンス一覧(2026-08-26更新)

Phase 8「依存ライセンス一覧を作成する」の成果物。Package.resolved(version 3)の全19依存について、DerivedDataのチェックアウト実体のLICENSEファイルで種別を確認した。バージョンはPackage.resolved記載の解決済みバージョン。

## アプリ本体に同梱される依存(製品配布時にライセンス表示が必要)

| パッケージ | バージョン | ライセンス | 提供元 | 用途 |
|---|---|---|---|---|
| Citadel | 0.12.1 | MIT | orlandos-nl | SFTPクライアント |
| SMBClient | 0.3.1 | MIT | kishikawakatsumi | SMB直接転送 |
| ZIPFoundation | 0.9.20 | MIT | weichsel | ZIP圧縮・展開 |
| PLzmaSDK | 1.6.1 | MIT | OlehKulykov | 7z圧縮・展開(LZMA SDK同梱) |
| SWCompression | 4.0.0 | MIT | tsolomko | tar系・gz/bz2/xz展開 |
| Unrar.swift | 0.5.4 | MIT | mtgto | RAR展開。UnRAR 7.23ソースを内包 |
| BigInt | 5.7.0 | MIT | attaswift | Citadelの推移的依存(暗号演算) |
| swift-nio | 2.101.3 | Apache 2.0 | apple | Citadelの推移的依存 |
| swift-nio-ssh | 0.3.6 | Apache 2.0 | Wellz26(フォーク) | Citadelの推移的依存。注意: apple公式ではなくフォーク参照(project.yml:25。Citadel経由の指定) |
| swift-crypto | 3.15.1 | Apache 2.0 | apple | 暗号処理 |
| swift-asn1 | 1.7.1 | Apache 2.0 | apple | 鍵のASN.1解析 |
| swift-atomics | 1.3.1 | Apache 2.0 | apple | NIO推移的依存 |
| swift-collections | 1.6.0 | Apache 2.0 | apple | NIO推移的依存 |
| swift-log | 1.14.0 | Apache 2.0 | apple | Citadel推移的依存 |
| swift-system | 1.7.5 | Apache 2.0 | apple | NIO推移的依存 |

## テスト・開発ツールのみ(製品バイナリに入らない。配布時のライセンス表示は不要)

| パッケージ | バージョン | ライセンス | 用途 |
|---|---|---|---|
| swift-snapshot-testing | 1.19.2 | MIT | VRT |
| swift-custom-dump | 1.6.1 | MIT | snapshot-testing推移的依存 |
| xctest-dynamic-overlay | 1.11.0 | MIT | snapshot-testing推移的依存 |
| swift-syntax | 603.0.2 | Apache 2.0 | マクロ・テストツール推移的依存 |

## パッケージ内包コンポーネント

| コンポーネント | バージョン | ライセンス | 同梱元 | 用途・条件 |
|---|---|---|---|---|
| UnRAR source | 7.23 | RARLAB UnRAR freeware license | Unrar.swift 0.5.4 | RAR展開のみ。RAR互換圧縮機の開発・RAR圧縮アルゴリズムの再作成は禁止。再配布時はライセンス所定段落の全文をライセンスまたは文書へ含める |

## 所見

- GPL/LGPL/MPL系のコピーレフトライセンスは存在しない。SPM依存はMITまたはApache 2.0、内包UnRARは無償再配布可能な独自freeware licenseで、RAR圧縮を実装しない本用途と両立する
- 義務: MITは著作権表示とライセンス文の同梱、Apache 2.0はライセンス文の同梱(+改変時の明示。本プロジェクトは改変なし)。UnRARは`Sources/Cunrar/license.txt`の所定段落を含むライセンス全文を掲示する。アプリ内ライセンス表示(ロードマップ13.3)で本体同梱15パッケージとUnRARの全文を掲示する
- 要注意1件: swift-nio-ssh がapple公式ではなく Wellz26 フォーク(0.3.6)を参照している。ライセンスはApache 2.0のままだが、公開準備時に公式リポジトリへ戻せるかの再評価を推奨(ロードマップ13.3の項目として扱う)
- テスト専用4件が製品ターゲットにリンクされていないことは、公開準備のRelease Archive確認時に最終検証する
