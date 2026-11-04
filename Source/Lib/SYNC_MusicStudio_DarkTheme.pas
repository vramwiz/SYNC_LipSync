unit SYNC_MusicStudio_DarkTheme;

// VCLフォームと共通操作部品へ、演奏スタジオ設定画面の暗色配色を適用する。

interface

uses
  System.Types,
  System.UITypes,
  Vcl.ComCtrls,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls;

const
  SYNC_MUSIC_STUDIO_DARK_BACKGROUND_COLOR = TColor($00202020);
  SYNC_MUSIC_STUDIO_DARK_PANEL_COLOR = TColor($00262626);
  SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR = TColor($00303030);
  SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR = TColor($00E6E6E6);

// フォーム本体とWindowsタイトルバーを暗色へ揃える。
procedure ApplySyncMusicStudioDarkForm(Form: TForm);
// フレームが親の明色背景を継承しないようにする。
procedure ApplySyncMusicStudioDarkFrame(Frame: TFrame);
// パネルの背景と文字色を揃える。
procedure ApplySyncMusicStudioDarkPanel(Panel: TPanel);
// 候補コンボを暗色の所有者描画に切り替える。
procedure ApplySyncMusicStudioDarkComboBox(ComboBox: TComboBox;
  DrawItemEvent: TDrawItemEvent);
// 文字入力欄の背景と文字色を揃える。
procedure ApplySyncMusicStudioDarkEdit(Edit: TEdit);
// 複数行入力欄の背景と文字色を揃える。
procedure ApplySyncMusicStudioDarkMemo(Memo: TMemo);
// 歌詞一覧の背景と文字色を揃える。
procedure ApplySyncMusicStudioDarkListBox(ListBox: TListBox);
// 配置要素一覧の背景と文字色を揃える。
procedure ApplySyncMusicStudioDarkListView(ListView: TListView);
// ボタンのVCL標準配色を暗色へ切り替える。
procedure ApplySyncMusicStudioDarkButton(Button: TButton);
// DPIに合わせた余白で候補コンボの1項目を描画する。
procedure DrawSyncMusicStudioDarkComboBoxItem(ComboBox: TComboBox;
  Index: Integer; const ItemRect: TRect; State: TOwnerDrawState;
  PPI: Integer);

implementation

uses
  Winapi.Dwmapi,
  Winapi.Windows,
  Winapi.UxTheme;

const
  DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

procedure EnableDarkTitleBar(Form: TForm);
var
  Enabled: BOOL;
begin
  Form.HandleNeeded;
  Enabled := True;
  if DwmSetWindowAttribute(Form.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE,
    @Enabled, SizeOf(Enabled)) <> S_OK then
    DwmSetWindowAttribute(Form.Handle,
      DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, @Enabled,
      SizeOf(Enabled));
end;

procedure ApplySyncMusicStudioDarkForm(Form: TForm);
begin
  Form.Color := SYNC_MUSIC_STUDIO_DARK_BACKGROUND_COLOR;
  Form.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  EnableDarkTitleBar(Form);
end;

procedure ApplySyncMusicStudioDarkFrame(Frame: TFrame);
begin
  Frame.ParentBackground := False;
  Frame.ParentColor := False;
  Frame.ParentFont := False;
  Frame.Color := SYNC_MUSIC_STUDIO_DARK_BACKGROUND_COLOR;
  Frame.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
end;

procedure ApplySyncMusicStudioDarkPanel(Panel: TPanel);
begin
  Panel.ParentBackground := False;
  Panel.Color := SYNC_MUSIC_STUDIO_DARK_PANEL_COLOR;
  Panel.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
end;

procedure ApplySyncMusicStudioDarkComboBox(ComboBox: TComboBox;
  DrawItemEvent: TDrawItemEvent);
begin
  ComboBox.Style := csOwnerDrawFixed;
  ComboBox.ItemHeight := MulDiv(16, ComboBox.CurrentPPI, 96);
  ComboBox.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  ComboBox.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  ComboBox.StyleElements := ComboBox.StyleElements - [seClient];
  ComboBox.OnDrawItem := DrawItemEvent;
  ComboBox.HandleNeeded;
  SetWindowTheme(ComboBox.Handle, 'DarkMode_CFD', nil);
end;

procedure ApplySyncMusicStudioDarkEdit(Edit: TEdit);
begin
  Edit.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  Edit.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  Edit.StyleElements := Edit.StyleElements - [seClient];
end;

procedure ApplySyncMusicStudioDarkMemo(Memo: TMemo);
begin
  Memo.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  Memo.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  Memo.StyleElements := Memo.StyleElements - [seClient];
end;

procedure ApplySyncMusicStudioDarkListBox(ListBox: TListBox);
begin
  ListBox.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  ListBox.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  ListBox.StyleElements := ListBox.StyleElements - [seClient];
  ListBox.HandleNeeded;
  SetWindowTheme(ListBox.Handle, 'DarkMode_Explorer', nil);
end;

procedure ApplySyncMusicStudioDarkListView(ListView: TListView);
begin
  ListView.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  ListView.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  ListView.StyleElements := ListView.StyleElements - [seClient];
  ListView.HandleNeeded;
  SetWindowTheme(ListView.Handle, 'DarkMode_Explorer', nil);
end;

procedure ApplySyncMusicStudioDarkButton(Button: TButton);
begin
  Button.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  Button.HandleNeeded;
  SetWindowTheme(Button.Handle, 'DarkMode_Explorer', nil);
end;

procedure DrawSyncMusicStudioDarkComboBoxItem(ComboBox: TComboBox;
  Index: Integer; const ItemRect: TRect; State: TOwnerDrawState;
  PPI: Integer);
var
  DrawRect: TRect;
  Text: string;
begin
  if odSelected in State then
  begin
    ComboBox.Canvas.Brush.Color := clHighlight;
    ComboBox.Canvas.Font.Color := clHighlightText;
  end
  else
  begin
    ComboBox.Canvas.Brush.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
    ComboBox.Canvas.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  end;
  ComboBox.Canvas.FillRect(ItemRect);
  if (Index < 0) or (Index >= ComboBox.Items.Count) then
    Exit;

  Text := ComboBox.Items[Index];
  DrawRect := ItemRect;
  Inc(DrawRect.Left, MulDiv(4, PPI, 96));
  DrawText(ComboBox.Canvas.Handle, PChar(Text), Length(Text), DrawRect,
    DT_LEFT or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);
end;

end.
