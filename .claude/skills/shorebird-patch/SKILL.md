---
name: shorebird-patch
description: Shorebird OTA パッチの作成・owner 配布（stable 昇格はユーザー確認後）
disable-model-invocation: true
allowed-tools: Bash(bash:*), Bash(shorebird:*), Bash(dart:*), Bash(xcrun:*), Bash(grep:*), Read
---

# Shorebird パッチ配布

署名済みの OTA パッチを `owner` に作成し、物理 iPhone で検証する。`stable` への昇格はユーザーが検証結果を確認した後だけ実行する。

## フロー

```
patch (owner) → 物理 iPhone で検証 → ユーザー確認 → stable → 他ユーザー
```

## 必須設定

- `apps/mobile/shorebird.yaml` は個人 Shorebird アカウントの `app_id` を使う。
- `CCPOCKET_SHOREBIRD_APP_ID` はその ID と完全一致させる。誤った上流アプリへの公開を防ぐ門禁である。
- `SHOREBIRD_PUBLIC_KEY_PATH` と `SHOREBIRD_PRIVATE_KEY_PATH` を設定する。
- 秘密鍵はリポジトリに置かない。紛失すると、その公開鍵を埋め込んだ base IPA に新しいパッチを発行できない。

## パッチ

```bash
bash .claude/skills/shorebird-patch/patch.sh ios <release-version>
```

`patch.sh` は次を強制する。

- 配布先は `owner`。
- RSA 公開鍵と秘密鍵で署名する。
- `--allow-native-diffs` と `--allow-asset-diffs` を拒否する。
- Native、Swift/Kotlin、entitlement、plugin、asset、Flutter/Xcode、依存関係の差分はパッチにせず、新しい base release にする。

## 新しい base IPA

```bash
bash .claude/skills/shorebird-patch/release.sh ios
```

このコマンドは公開鍵を base release に埋め込む。初回、または native/asset 差分がある場合に使う。iOS Simulator は UI と通常ビルドだけに使い、Shorebird パッチは物理 iPhone で検証する。

## owner の実機確認

1. 設定のバージョン番号を7回タップして開発者更新通道を解锁する。
2. ソフトウェア更新で `owner` を選ぶ。
3. 「检查更新」を押し、表示された更新を明示的にダウンロードする。
4. App を完全に終了して再度開き、patch 番号と変更内容を確認する。
5. AltStore の再署名後も patch が残ることを物理端末で確認する。

## stable への昇格

ユーザーが明示的に確認した後だけ実行する。

```bash
bash .claude/skills/shorebird-patch/promote.sh \
  <release-version> <patch-number> --confirm-stable
```

中間の owner patch を全て昇格する必要はない。検証済みの指定 patch だけを stable に設定する。

## ロールバック

stable に問題があれば Shorebird Console で対象 patch の Rollback を実行する。ロールバック後、App の手動チェックと再起動で前の正常 patch または base release に戻ったことを物理 iPhone で確認する。エージェントはユーザーの明示確認なしに stable の変更やロールバックを実行しない。

## 完了報告

- platform / base release version / patch number
- app_id の照合結果（ID 自体は秘密ではない）
- track が `owner` であり、stable は未変更であること
- native/asset diff の有無
- 署名済みであること（秘密鍵の内容やパスはログに出さない）
- 物理 iPhone の検証結果
