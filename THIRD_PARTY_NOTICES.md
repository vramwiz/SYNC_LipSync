# 移植元と使用コンポーネント

- **SYNC_MusicStudio** — PSD の読み込みと合成、歌唱データ解析、テンポ計算、音声の波形・試聴、アニメーションなどの処理を移植しています。
- **AviUtl2PluginLib / PSDArtEditor** — PSD の読み込み、レイヤー構造、合成に使うコードの移植元です。由来は該当ユニットの先頭に記載しています。
- **SongReader** — SMF の読み込み方式と、歌詞からかな母音を取り出す処理の参照元です。
- **SYNC_Motion** — 拍に合わせたアニメーション曲線と画像変形処理の移植元です。

MP3 の読み込みには Windows Media Format（`wmvcore.dll`）を使用します。設定画面とビルドには Delphi / VCL、ホストとの連携には AviUtl2 のフィルタープラグイン API を使用します。

リポジトリのライセンス本文は [LICENSE](LICENSE) にあります。

