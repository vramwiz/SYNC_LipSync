unit SYNC_LipSync_SettingsForm;

// 素材選択、口差分の割当とシーン上の配置プレビューを担当する。

interface

uses
  Winapi.Messages, System.Classes, System.JSON, System.Types,
  Vcl.Controls, Vcl.Forms, Vcl.Graphics, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Menus,
  SYNC_LipSync_Scene, SYNC_LipSync_PreviewViewport, SYNC_MusicStudio_HostBackground,
  SYNC_MusicStudio_PsdTransform;

type
  TLipSyncApply = reference to procedure(const PsdPath, MusicPath, JSON: string);

  TFormLipSyncSettings = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FPsd, FMusic, FX, FY, FScale, FThreshold, FTime: TEdit;
    FLayers: TTreeView;
    FLayerMenu: TPopupMenu;
    FLayerKey, FTreePath: string;
    FPreviewMouth: TComboBox;
    FBlinkSpeed, FMouthSpeed: TTrackBar;
    FBlinkValue, FMouthValue, FLiveState: TLabel;
    FPreviewTick: UInt64;
    FPreviewSeconds: Double;
    FLiveSlot, FLiveStep, FLastEye: Integer;
    FSmooth, FFlipX, FFlipY: TCheckBox;
    FStatus: TLabel;
    FPreview: TPaintBox;
    FTimer: TTimer;
    FConfig: TJSONObject;
    FScene: TLipSyncScene;
    FBackground, FImage, FPreviewBuffer: TBitmap;
    FImageDirty, FImageReady: Boolean;
    FLastMusicStatus: string;
    FBackgroundReader: TMusicStudioReadBackground;
    FFrameWidth, FFrameHeight: Integer;
    FPreviewFrame, FPlacementBounds, FDragBounds, FDragFrame: TRect;
    FDragOrigin, FPanMouse: TPoint;
    FViewport: TLipSyncPreviewViewport;
    FPanning: Boolean;
    FDragTransform: TMusicStudioPsdTransform;
    FGrip: Integer;
    FPlacementSelected: Boolean;
    FSerial: UInt64;
    FApply: TLipSyncApply;
    FLoading, FDragging: Boolean;
    FBackgroundStatus: string;
    FOKButton, FCancelButton: TButton;
    FMusicLabel: TLabel;
    FEmbedded: Boolean;
    procedure DropFiles(var Msg: TMessage); message WM_DROPFILES;
    procedure Reload(Sender: TObject);
    procedure Change(Sender: TObject);
    procedure PaintPreview(Sender: TObject);
    procedure PreviewWheel(Sender: TObject; Shift: TShiftState; Delta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure Tick(Sender: TObject);
    function UpdateLiveSample: Boolean;
    procedure PreviewMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure PreviewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PreviewMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure Apply(Sender: TObject);
    procedure BuildLayerTree;
    procedure RefreshLayerCaptions;
    function SelectedLayerIndex: Integer;
    procedure LayerChanged(Sender: TObject; Node: TTreeNode);
    procedure LayerContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure AssignLayer(Sender: TObject);
    procedure DrawPreviewItem(Control: TWinControl; Index: Integer;
      Rect: TRect; State: TOwnerDrawState);
    procedure DrawMenuItem(Sender: TObject; ACanvas: TCanvas; ARect: TRect;
      Selected: Boolean);
    procedure UpdateConfig;
    procedure ShowTransform(const Transform: TMusicStudioPsdTransform);
    function HitPlacement(X, Y: Integer): Integer;
    procedure PaintPlacement(Canvas: TCanvas);
    procedure SetNumber(const Key: string; Edit: TEdit; Default, Low, High: Double);
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
  public
    procedure SetEmbedded;
    // 編集中の配置と差分を検証し、成功時だけ呼出側のモデルへ反映する。
    function CommitSettings: Boolean;
    // ApplySettings はモーダル表示中のみ呼び出し、設定確定時に使用する。
    procedure LoadSettings(const PsdPath, MusicPath, JSON: string;
      FrameWidth, FrameHeight: Integer; const ReadBackground: TMusicStudioReadBackground;
      const ApplySettings: TLipSyncApply);
  end;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI, System.SysUtils, System.Math, System.UITypes,
  Winapi.UxTheme, System.Generics.Collections,
  Vcl.Dialogs, SYNC_MusicStudio_PsdLayers, SYNC_MusicStudio_PsdLayerConfig,
  SYNC_MusicStudio_DarkTheme;

{$R *.dfm}

type
  TPreviewPaintBox = class(TPaintBox)
  public
    constructor Create(AOwner: TComponent); override;
  end;
  TDarkCheckBox = class(TCheckBox)
  private
    procedure PaintCheck(DC: HDC);
    procedure WMPaint(var Msg: TWMPaint); message WM_PAINT;
  protected
    procedure WndProc(var Msg: TMessage); override;
  end;

constructor TPreviewPaintBox.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];
end;

procedure TDarkCheckBox.PaintCheck(DC: HDC);
var
  Surface: TCanvas;
  Bounds, Box, TextBounds: TRect;
  Size, Top, SavedDC: Integer;
begin
  SavedDC := SaveDC(DC);
  if SavedDC = 0 then Exit;
  Surface := TCanvas.Create;
  try
    Surface.Handle := DC;
    Surface.Font.Assign(Font);
    Surface.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
    Bounds := ClientRect;
    Surface.Brush.Color := SYNC_MUSIC_STUDIO_DARK_PANEL_COLOR;
    Surface.FillRect(Bounds);
    Size := MulDiv(14, CurrentPPI, 96);
    Top := (Bounds.Height - Size) div 2;
    Box := Rect(1, Top, 1 + Size, Top + Size);
    Surface.Brush.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
    Surface.Pen.Color := $00848484;
    if Checked then Surface.Brush.Color := $00AE733C;
    Surface.Rectangle(Box);
    if Checked then
    begin
      Surface.Pen.Color := clWhite;
      Surface.Pen.Width := Max(1, MulDiv(2, CurrentPPI, 96));
      Surface.MoveTo(Box.Left + Size div 5, Box.Top + Size div 2);
      Surface.LineTo(Box.Left + Size * 2 div 5, Box.Top + Size * 3 div 4);
      Surface.LineTo(Box.Right - Size div 6, Box.Top + Size div 4);
    end;
    TextBounds := Bounds;
    TextBounds.Left := Box.Right + MulDiv(6, CurrentPPI, 96);
    SelectObject(DC, Surface.Font.Handle);
    SetTextColor(DC, ColorToRGB(Surface.Font.Color));
    SetBkMode(DC, TRANSPARENT);
    DrawText(DC, PChar(Caption), Length(Caption), TextBounds,
      DT_SINGLELINE or DT_VCENTER or DT_NOPREFIX);
    if Focused then
    begin
      TextBounds.Right := Min(TextBounds.Right, TextBounds.Left + Surface.TextWidth(Caption) + 2);
      DrawFocusRect(DC, TextBounds);
    end;
  finally
    Surface.Handle := 0;
    Surface.Free;
    RestoreDC(DC, SavedDC);
  end;
end;

procedure TDarkCheckBox.WMPaint(var Msg: TWMPaint);
var
  Paint: TPaintStruct;
  DC: HDC;
begin
  DC := Msg.DC;
  if DC <> 0 then
    PaintCheck(DC)
  else
  begin
    DC := BeginPaint(Handle, Paint);
    try
      PaintCheck(DC);
    finally
      EndPaint(Handle, Paint);
    end;
  end;
end;

procedure TDarkCheckBox.WndProc(var Msg: TMessage);
begin
  if Msg.Msg = WM_PRINTCLIENT then
  begin
    PaintCheck(HDC(Msg.WParam));
    Exit;
  end;
  inherited;
  if Msg.Msg in [WM_SETFOCUS, WM_KILLFOCUS] then Invalidate;
  if Msg.Msg = BM_SETCHECK then Invalidate;
end;

const
  PREVIEW_SONG_SAMPLE = High(LIP_SYNC_SLOT_NAMES) + 3;
  PREVIEW_OPEN_SAMPLE = PREVIEW_SONG_SAMPLE + 1;
  EYE_MENU_TAG = 100;

procedure TFormLipSyncSettings.FormCreate(Sender: TObject);
var
  Panel, PreviewTools: TPanel;
  I: Integer;
  Button: TButton;
  MenuItem, Category: TMenuItem;
  Eye: TLipSyncEye;
  function LabelAt(const Caption: string; X, Y: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Panel;
    Result.Left := X;
    Result.Top := Y;
    Result.Caption := Caption;
  end;
  function EditAt(X, Y, Width: Integer; OnChange: TNotifyEvent): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := Panel;
    Result.SetBounds(X, Y, Width, 24);
    Result.OnChange := OnChange;
    ApplySyncMusicStudioDarkEdit(Result);
  end;
  function ButtonAt(const Caption: string; X, Y: Integer; Click: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Panel;
    Result.SetBounds(X, Y, 74, 25);
    Result.Caption := Caption;
    Result.OnClick := Click;
    ApplySyncMusicStudioDarkButton(Result);
  end;
  function CheckAt(const Caption: string; X, Y, Width: Integer): TCheckBox;
  begin
    Result := TDarkCheckBox.Create(Self);
    Result.Parent := Panel;
    Result.SetBounds(X, Y, Width, 24);
    Result.Caption := Caption;
    Result.OnClick := Change;
  end;
  function ComboAt(X, Y, Width: Integer): TComboBox;
  begin
    Result := TComboBox.Create(Self);
    Result.Parent := Panel;
    Result.SetBounds(X, Y, Width, 25);
    ApplySyncMusicStudioDarkComboBox(Result, DrawPreviewItem);
    Result.OnChange := Change;
  end;
  function MenuBranch(const Caption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(FLayerMenu);
    Result.Caption := Caption;
    Result.OnDrawItem := DrawMenuItem;
    FLayerMenu.Items.Add(Result);
  end;
  procedure AddAssignment(ParentItem: TMenuItem; const Caption: string; Tag: Integer);
  var Item: TMenuItem;
  begin
    Item := TMenuItem.Create(FLayerMenu);
    Item.Caption := Caption;
    Item.Tag := Tag;
    Item.OnClick := AssignLayer;
    Item.OnDrawItem := DrawMenuItem;
    ParentItem.Add(Item);
  end;
  function SpeedSlider(Y: Integer): TTrackBar;
  begin
    Result := TTrackBar.Create(Self);
    Result.Parent := PreviewTools;
    Result.SetBounds(112,Y,115,26);
    Result.Min := 5;
    Result.Max := 20;
    Result.Position := 10;
    Result.TickStyle := tsNone;
    Result.OnChange := Change;
    SetWindowTheme(Result.Handle,'DarkMode_Explorer',nil);
  end;
begin
  ApplySyncMusicStudioDarkForm(Self);
  FScene := TLipSyncScene.Create;
  FImage := Vcl.Graphics.TBitmap.Create;
  FPreviewBuffer := Vcl.Graphics.TBitmap.Create;
  FPreviewBuffer.PixelFormat := pf32bit;
  FImageDirty := True;
  FBackground := Vcl.Graphics.TBitmap.Create;

  Panel := TPanel.Create(Self);
  Panel.Parent := Self;
  Panel.Align := alLeft;
  Panel.Width := 380;
  Panel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(Panel);

  LabelAt('PSD（ここにドロップして変更）', 12, 12);
  FPsd := EditAt(12, 32, 354, nil);
  FPsd.ReadOnly := True;
  FPsd.TabStop := False;
  FMusicLabel := LabelAt('音楽ファイル（ドロップ）', 12, 64);
  FMusic := EditAt(12, 84, 354, nil);
  FMusic.ReadOnly := True;
  FMusic.TabStop := False;

  LabelAt('PSD レイヤー  ・  選択で試写 / 右クリックで割当', 12, 121);
  FLayers := TTreeView.Create(Self);
  FLayers.Parent := Panel;
  FLayers.SetBounds(12, 146, 354, 241);
  FLayers.ReadOnly := True;
  FLayers.HideSelection := False;
  FLayers.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  FLayers.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  FLayers.StyleElements := FLayers.StyleElements - [seClient];
  FLayers.OnChange := LayerChanged;
  FLayers.OnContextPopup := LayerContextPopup;
  SetWindowTheme(FLayers.Handle, 'DarkMode_Explorer', nil);

  FLayerMenu := TPopupMenu.Create(Self);
  FLayerMenu.OwnerDraw := True;
  Category := MenuBranch('目パチ');
  for Eye := Low(Eye) to High(Eye) do
    AddAssignment(Category,LIP_SYNC_EYE_NAMES[Eye],EYE_MENU_TAG+Ord(Eye));
  Category := MenuBranch('口パク（開閉）');
  AddAssignment(Category,LIP_SYNC_SLOT_NAMES[0],0);
  for I := 7 to High(LIP_SYNC_SLOT_NAMES) do
    AddAssignment(Category,LIP_SYNC_SLOT_NAMES[I],I);
  Category := MenuBranch('口パク（ソング）');
  AddAssignment(Category,LIP_SYNC_SLOT_NAMES[0],0);
  for I := 1 to 6 do AddAssignment(Category,LIP_SYNC_SLOT_NAMES[I],I);
  MenuItem := TMenuItem.Create(FLayerMenu);
  MenuItem.Caption := '-';
  FLayerMenu.Items.Add(MenuItem);
  AddAssignment(FLayerMenu.Items,'このレイヤーの割当を解除',-1);

  FSmooth := CheckAt('口の差分を縮小描画して開閉を滑らかにする', 12, 391, 354);
  FFlipX := CheckAt('左右反転', 12, 415, 104);
  FFlipY := CheckAt('上下反転', 124, 415, 104);
  LabelAt('中心 X / Y (px)', 12, 450);
  FX := EditAt(118, 446, 55, Change);
  FY := EditAt(179, 446, 55, Change);
  LabelAt('倍率 (%)', 243, 450);
  FScale := EditAt(311, 446, 55, Change);
  LabelAt('音量しきい値 (%)', 12, 480);
  FThreshold := EditAt(118, 476, 55, Change);
  LabelAt('試写時刻 (秒)', 195, 480);
  FTime := EditAt(311, 476, 55, Change);
  FTime.Text := '0';
  LabelAt('試写する口', 12, 510);
  FPreviewMouth := ComboAt(118, 506, 248);
  FPreviewMouth.Items.Add('音楽に合わせる');
  FPreviewMouth.Items.Add('選択レイヤー');
  for I := 0 to High(LIP_SYNC_SLOT_NAMES) do
    FPreviewMouth.Items.Add(LIP_SYNC_SLOT_NAMES[I]);
  FPreviewMouth.Items.Add('自動試写（ソング）');
  FPreviewMouth.Items.Add('自動試写（開閉）');
  FPreviewMouth.ItemIndex := PREVIEW_SONG_SAMPLE;

  Button := ButtonAt('OK', 210, 548, Apply);
  FOKButton := Button;
  Button.Default := True;
  Button := ButtonAt('キャンセル', 292, 548, nil);
  FCancelButton := Button;
  Button.Cancel := True;
  Button.ModalResult := mrCancel;

  Panel := TPanel.Create(Self);
  Panel.Parent := Self;
  Panel.Align := alClient;
  Panel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(Panel);
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Panel;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 70;
  FStatus.WordWrap := True;
  FLiveState := TLabel.Create(Self);
  FLiveState.Parent := Panel;
  FLiveState.Align := alBottom;
  FLiveState.AutoSize := False;
  FLiveState.Height := 26;
  FLiveState.Layout := tlCenter;

  PreviewTools := TPanel.Create(Self);
  PreviewTools.Parent := Panel;
  PreviewTools.Align := alTop;
  PreviewTools.Height := 58;
  PreviewTools.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(PreviewTools);
  Panel := PreviewTools;
  LabelAt('目パチ速度',8,8);
  FBlinkSpeed := SpeedSlider(3);
  FBlinkValue := LabelAt('',235,8);
  LabelAt('口パク試写速度',8,33);
  FMouthSpeed := SpeedSlider(28);
  FMouthValue := LabelAt('',235,33);
  Panel := PreviewTools.Parent as TPanel;

  FPreview := TPreviewPaintBox.Create(Self);
  FPreview.Parent := Panel;
  FPreview.Align := alClient;
  FPreview.OnPaint := PaintPreview;
  FPreview.OnMouseDown := PreviewMouseDown;
  FPreview.OnMouseMove := PreviewMouseMove;
  FPreview.OnMouseUp := PreviewMouseUp;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 50;
  FPreviewTick := GetTickCount64;
  FLastEye := -1;
  FLiveSlot := -1;
  FLiveStep := -1;
  FTimer.OnTimer := Tick;
  OnMouseWheel := PreviewWheel;
end;

procedure TFormLipSyncSettings.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TFormLipSyncSettings.DestroyWnd;
begin
  DragAcceptFiles(Handle, False);
  inherited;
end;

procedure TFormLipSyncSettings.FormDestroy(Sender: TObject);
begin
  if Assigned(FTimer) then FTimer.Enabled := False;
  FConfig.Free;
  FScene.Free;
  FImage.Free;
  FPreviewBuffer.Free;
  FBackground.Free;
end;

procedure TFormLipSyncSettings.LoadSettings(const PsdPath, MusicPath, JSON: string;
  FrameWidth, FrameHeight: Integer; const ReadBackground: TMusicStudioReadBackground;
  const ApplySettings: TLipSyncApply);
begin
  FLoading := True;
  try
    FBackgroundReader := ReadBackground;
    FApply := ApplySettings;
    FFrameWidth := Max(1, FrameWidth);
    FFrameHeight := Max(1, FrameHeight);
    FConfig := ParseMusicStudioPsdConfig(JSON);
    FPsd.Text := PsdPath;
    FMusic.Text := MusicPath;
    FScene.Configure(PsdPath, MusicPath, FConfig.ToJSON);
    ShowTransform(FScene.TransformFor(FFrameWidth, FFrameHeight));
    FThreshold.Text := FloatToStr(LipSyncNumber(FConfig, 'threshold', 8, 0, 99));
    FSmooth.Checked := MusicStudioAnimateMouthSize(FConfig);
    FBlinkSpeed.Position := Round(10*LipSyncNumber(FConfig,'blinkSpeed',1,0.5,2));
    FMouthSpeed.Position := Round(10*LipSyncNumber(FConfig,'sampleMouthSpeed',1,0.5,2));
    FPreviewTick := GetTickCount64;
  finally
    FLoading := False;
  end;
  Reload(nil);
  FTimer.Enabled := True;
end;

procedure TFormLipSyncSettings.DrawPreviewItem(Control: TWinControl; Index: Integer;
  Rect: TRect; State: TOwnerDrawState);
begin
  DrawSyncMusicStudioDarkComboBoxItem(TComboBox(Control), Index, Rect, State, CurrentPPI);
end;

procedure TFormLipSyncSettings.DrawMenuItem(Sender: TObject; ACanvas: TCanvas;
  ARect: TRect; Selected: Boolean);
begin
  if Selected then
    ACanvas.Brush.Color := clHighlight
  else
    ACanvas.Brush.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  ACanvas.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  ACanvas.FillRect(ARect);
  ACanvas.TextOut(ARect.Left + 6, ARect.Top + 2, TMenuItem(Sender).Caption);
end;

procedure TFormLipSyncSettings.BuildLayerTree;
var
  Nodes: TDictionary<string, TTreeNode>;
  Layer: TMusicStudioLayerInfo;
  Parent, Node: TTreeNode;
  I: Integer;
begin
  if FTreePath = FScene.Document.FilePath then Exit;
  FTreePath := FScene.Document.FilePath;
  FLayerKey := '';
  FPlacementSelected := False;
  Nodes := TDictionary<string, TTreeNode>.Create;
  FLayers.Items.BeginUpdate;
  try
    FLayers.Items.Clear;
    for I := 0 to High(FScene.Document.Layers) do
    begin
      Layer := FScene.Document.Layers[I];
      if not Nodes.TryGetValue(Layer.ParentKey, Parent) then Parent := nil;
      Node := FLayers.Items.AddChildObject(Parent, Layer.Name, Pointer(NativeInt(I + 1)));
      Nodes.Add(Layer.Key, Node);
    end;
    RefreshLayerCaptions;
    FLayers.FullExpand;
  finally
    FLayers.Items.EndUpdate;
    Nodes.Free;
  end;
end;

procedure TFormLipSyncSettings.RefreshLayerCaptions;
var
  Layer: TMusicStudioLayerInfo;
  Node: TTreeNode;
  Slot: Integer;
  Keys: array[0..9] of string;
  EyeKeys: array[TLipSyncEye] of string;
  Eye: TLipSyncEye;
  Caption: string;
begin
  for Slot := 0 to High(Keys) do Keys[Slot] := LipSyncLayer(FConfig, Slot);
  for Eye := Low(Eye) to High(Eye) do EyeKeys[Eye] := LipSyncEyeLayer(FConfig,Eye);
  Node := FLayers.Items.GetFirstNode;
  while Node <> nil do
  begin
    Layer := FScene.Document.Layers[NativeInt(Node.Data) - 1];
    Caption := Layer.Name;
    for Slot := 0 to High(Keys) do
      if Keys[Slot] = Layer.Key then
        Caption := Caption + '  [' + LIP_SYNC_SLOT_NAMES[Slot] + ']';
    for Eye := Low(Eye) to High(Eye) do
      if EyeKeys[Eye]=Layer.Key then Caption := Caption+'  ['+LIP_SYNC_EYE_NAMES[Eye]+']';
    Node.Text := Caption;
    Node := Node.GetNext;
  end;
end;

function TFormLipSyncSettings.SelectedLayerIndex: Integer;
begin
  if FLayers.Selected = nil then Exit(-1);
  Result := NativeInt(FLayers.Selected.Data) - 1;
end;

procedure TFormLipSyncSettings.LayerChanged(Sender: TObject; Node: TTreeNode);
begin
  if FLoading or (Node = nil) then Exit;
  FLayerKey := FScene.Document.Layers[NativeInt(Node.Data) - 1].Key;
  FPreviewMouth.ItemIndex := 1;
  FImageDirty := True;
  FPreview.Invalidate;
end;

procedure TFormLipSyncSettings.LayerContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  Node: TTreeNode;
  Bounds: TRect;
begin
  Handled := True;
  if MousePos.X >= 0 then
    Node := FLayers.GetNodeAt(MousePos.X, MousePos.Y)
  else
    Node := FLayers.Selected;
  if Node = nil then Exit;
  FLayers.Selected := Node;
  LayerChanged(FLayers, Node);
  if FScene.Document.Layers[SelectedLayerIndex].IsGroup then Exit;
  if MousePos.X < 0 then
  begin
    Bounds := Node.DisplayRect(True);
    MousePos := Point(Bounds.Left, Bounds.Bottom);
  end;
  MousePos := FLayers.ClientToScreen(MousePos);
  FLayerMenu.Popup(MousePos.X, MousePos.Y);
end;

procedure TFormLipSyncSettings.AssignLayer(Sender: TObject);
var
  Index, Slot: Integer;
  Eye: TLipSyncEye;
  Key: string;
begin
  Index := SelectedLayerIndex;
  if (Index < 0) or FScene.Document.Layers[Index].IsGroup then Exit;
  Key := FScene.Document.Layers[Index].Key;
  Slot := TMenuItem(Sender).Tag;
  if Slot >= EYE_MENU_TAG then
  begin
    AssignLipSyncEye(FConfig,TLipSyncEye(Slot-EYE_MENU_TAG),Key);
    FPreviewMouth.ItemIndex := PREVIEW_SONG_SAMPLE;
  end
  else if Slot >= 0 then
  begin
    AssignLipSyncLayer(FConfig,Slot,Key);
    if Slot>=7 then FPreviewMouth.ItemIndex := PREVIEW_OPEN_SAMPLE
    else FPreviewMouth.ItemIndex := PREVIEW_SONG_SAMPLE;
  end
  else
  begin
    for Slot := 0 to High(LIP_SYNC_SLOT_NAMES) do
      if LipSyncLayer(FConfig,Slot)=Key then AssignLipSyncLayer(FConfig,Slot,'');
    for Eye := Low(Eye) to High(Eye) do
      if LipSyncEyeLayer(FConfig,Eye)=Key then AssignLipSyncEye(FConfig,Eye,'');
  end;
  RefreshLayerCaptions;
  Change(nil);
end;

procedure TFormLipSyncSettings.Reload(Sender: TObject);
begin
  if FLoading or (FConfig = nil) then Exit;
  FLoading := True;
  try
    try
      FScene.Configure(Trim(FPsd.Text), Trim(FMusic.Text), FConfig.ToJSON);
      BuildLayerTree;
      FImageDirty := True;
      FPreview.Invalidate;
      Tick(nil);
    except
      on E: Exception do FStatus.Caption := E.Message;
    end;
  finally
    FLoading := False;
  end;
end;

procedure TFormLipSyncSettings.DropFiles(var Msg: TMessage);
var
  Drop: HDROP;
  I, Count, Size: Cardinal;
  Path: string;
begin
  Drop := HDROP(Msg.WParam);
  try
    Count := DragQueryFile(Drop, $FFFFFFFF, nil, 0);
    I := 0;
    while I < Count do
    begin
      Size := DragQueryFile(Drop, I, nil, 0);
      SetLength(Path, Size);
      DragQueryFile(Drop, I, PChar(Path), Size + 1);
      if SameText(ExtractFileExt(Path), '.psd') then FPsd.Text := Path
      else if not FEmbedded and (LipSyncMode(Path) <> lmNone) then FMusic.Text := Path;
      Inc(I);
    end;
  finally
    DragFinish(Drop);
  end;
  Reload(nil);
end;

procedure TFormLipSyncSettings.SetNumber(const Key: string; Edit: TEdit; Default, Low, High: Double);
var
  Value: Double;
begin
  if not TryStrToFloat(Edit.Text, Value) or IsNan(Value) or IsInfinite(Value) then
    Value := LipSyncNumber(FConfig, Key, Default, Low, High);
  FConfig.RemovePair(Key).Free;
  FConfig.AddPair(Key, TJSONNumber.Create(EnsureRange(Value, Low, High)));
end;

procedure TFormLipSyncSettings.ShowTransform(const Transform: TMusicStudioPsdTransform);
begin
  FX.Text := FormatFloat('0.###', Transform.StageX);
  FY.Text := FormatFloat('0.###', Transform.StageY);
  FScale.Text := FormatFloat('0.###', Transform.Scale * 100);
  FFlipX.Checked := Transform.FlipX;
  FFlipY.Checked := Transform.FlipY;
end;

procedure TFormLipSyncSettings.UpdateConfig;
var
  Transform: TMusicStudioPsdTransform;
  function ReadNumber(Edit: TEdit; Default, Low, High: Double): Double;
  begin
    if not TryStrToFloat(Edit.Text, Result) or IsNan(Result) or IsInfinite(Result) then
      Result := Default;
    Result := EnsureRange(Result, Low, High);
  end;
begin
  Transform := FScene.TransformFor(FFrameWidth, FFrameHeight);
  Transform.StageX := ReadNumber(FX, Transform.StageX, -30720, 30720);
  Transform.StageY := ReadNumber(FY, Transform.StageY, -17280, 17280);
  Transform.Scale := ReadNumber(FScale, Transform.Scale * 100, 0.1, 25600) / 100;
  Transform.FlipX := FFlipX.Checked;
  Transform.FlipY := FFlipY.Checked;
  WriteMusicStudioPsdTransform(FConfig, Transform);
  MusicStudioSetJsonBoolean(FConfig, 'animateMouthSize', FSmooth.Checked);
  FConfig.RemovePair('blinkSpeed').Free;
  FConfig.AddPair('blinkSpeed',TJSONNumber.Create(FBlinkSpeed.Position/10));
  FConfig.RemovePair('sampleMouthSpeed').Free;
  FConfig.AddPair('sampleMouthSpeed',TJSONNumber.Create(FMouthSpeed.Position/10));
  SetNumber('threshold', FThreshold, 8, 0, 99);
end;

procedure TFormLipSyncSettings.Change(Sender: TObject);
begin
  if FLoading or (FConfig = nil) or (FPreview = nil) then Exit;
  try
    UpdateConfig;
    FScene.Configure(Trim(FPsd.Text), Trim(FMusic.Text), FConfig.ToJSON);
    if UpdateLiveSample then FImageDirty := True;
    if (Sender <> FX) and (Sender <> FY) and (Sender <> FScale) then
      FImageDirty := True;
    FPreview.Invalidate;
  except
    on E: Exception do FStatus.Caption := E.Message;
  end;
end;

function TFormLipSyncSettings.UpdateLiveSample: Boolean;
const OpeningNames: array[0..3] of string = ('閉じ口','小開き','中開き','全開');
var
  Mode, Slot, SongSlot, Opening, Step, Eye: Integer;
  MediaSeconds: Double;
  Caption, EyeText: string;
begin
  FPreviewSeconds := (GetTickCount64-FPreviewTick)/1000.0;
  Mode := FPreviewMouth.ItemIndex;
  Eye := -1;
  EyeText := '未割当';
  if (Mode<>1) and FScene.HasEyeAssignment then
  begin
    Eye := Ord(FScene.EyeAt(FPreviewSeconds));
    EyeText := LIP_SYNC_EYE_NAMES[TLipSyncEye(Eye)];
  end;
  FBlinkValue.Caption := FormatFloat('0.0',FBlinkSpeed.Position/10)+'倍';
  FMouthValue.Caption := FormatFloat('0.0',FMouthSpeed.Position/10)+'倍';
  Slot := -1;
  Step := 3;
  SongSlot := 0;
  Opening := 0;
  if Mode>=PREVIEW_SONG_SAMPLE then
  begin
    LipSyncSampleMouth(FPreviewSeconds,FMouthSpeed.Position/10,SongSlot,Opening);
    Slot := SongSlot;
    if (Mode=PREVIEW_OPEN_SAMPLE) and (Opening>0) then Slot := 6+Opening;
    Step := Max(1,Opening);
  end
  else if Mode=0 then
  begin
    MediaSeconds := StrToFloatDef(FTime.Text,0);
    if IsNan(MediaSeconds) or IsInfinite(MediaSeconds) then MediaSeconds := 0;
    FScene.MouthAt(MediaSeconds,Slot,Step);
    if Slot in [1..6] then SongSlot := Slot;
    if Slot>0 then Opening := Step;
  end
  else if Mode>1 then
  begin
    Slot := Mode-2;
    if Slot in [1..6] then SongSlot := Slot;
    if Slot>=7 then Opening := Slot-6
    else if Slot>0 then Opening := 3;
  end;
  if Mode=1 then Caption := '選択レイヤーを試写中'
  else
  begin
    if SongSlot=0 then Caption := '音素  —'
    else Caption := '音素  '+LIP_SYNC_SLOT_NAMES[SongSlot];
    Caption := Caption+'    開閉  '+OpeningNames[Opening]+'    目パチ  '+EyeText;
  end;
  if FLiveState.Caption<>Caption then FLiveState.Caption := Caption;
  Result := (Slot<>FLiveSlot) or (FSmooth.Checked and (Step<>FLiveStep)) or (Eye<>FLastEye);
  FLiveSlot := Slot;
  FLiveStep := Step;
  FLastEye := Eye;
end;

procedure TFormLipSyncSettings.Tick(Sender: TObject);
var
  Snapshot: TMusicStudioBackgroundSnapshot;
  X, Y: Integer;
  Row: PByte;
  Pixel: TMusicStudioFramePixels;
  MusicStatus, StatusText: string;
  Refresh: Boolean;
begin
  Refresh := False;
  if Assigned(FBackgroundReader) and FBackgroundReader(FSerial, Snapshot) and (Length(Snapshot.Pixels) > 0) then
  begin
    FSerial := Snapshot.Serial;
    Pixel := Snapshot.Pixels;
    FBackground.PixelFormat := pf32bit;
    FBackground.SetSize(Snapshot.Width, Snapshot.Height);
    for Y := 0 to Snapshot.Height - 1 do
    begin
      Row := FBackground.ScanLine[Y];
      for X := 0 to Snapshot.Width - 1 do
        with Pixel[Y * Snapshot.Width + X] do
        begin
          Row[X * 4] := B;
          Row[X * 4 + 1] := G;
          Row[X * 4 + 2] := R;
          Row[X * 4 + 3] := 0;
        end;
    end;
    FBackgroundStatus := Snapshot.Status;
    Refresh := True;
    if Sender = nil then
      FTime.Text := FloatToStr(Max(0, Snapshot.Seconds));
  end;
  MusicStatus := FScene.MusicStatus;
  if MusicStatus <> FLastMusicStatus then
  begin
    FLastMusicStatus := MusicStatus;
    if FPreviewMouth.ItemIndex = 0 then
    begin
      FImageDirty := True;
      Refresh := True;
    end;
  end;
  StatusText := MusicStatus;
  if (Trim(FPsd.Text) <> '') and not FScene.Document.Loaded then
    StatusText := StatusText + sLineBreak + FScene.Document.LastError;
  if FBackground.Empty then
    StatusText := StatusText + sLineBreak + '背景未取得。AviUtl2 で対象フレームを表示してから開いてください。'
  else
    StatusText := StatusText + sLineBreak + FBackgroundStatus + '。PSD をクリックして選択し、枠内で移動、四隅で拡縮できます。';
  if FStatus.Caption <> StatusText then FStatus.Caption := StatusText;
  if UpdateLiveSample then
  begin
    FImageDirty := True;
    Refresh := True;
  end;
  if Refresh then FPreview.Invalidate;
end;

procedure TFormLipSyncSettings.PaintPreview(Sender: TObject);
var
  Seconds: Double;
  Target: TRect;
  Blend: TBlendFunction;
  PreviewDC: HDC;
  PreviewKey: string;
  SavedDC: Integer;
  Surface: TCanvas;
begin
  if (FPreview.Width <= 0) or (FPreview.Height <= 0) then Exit;
  FPreviewBuffer.SetSize(FPreview.Width, FPreview.Height);
  Surface := FPreviewBuffer.Canvas;
  Surface.Brush.Color := SYNC_MUSIC_STUDIO_DARK_BACKGROUND_COLOR;
  Surface.FillRect(FPreview.ClientRect);
  if (FFrameWidth = 0) or (FFrameHeight = 0) then
  begin
    FPreview.Canvas.Draw(0, 0, FPreviewBuffer);
    Exit;
  end;
  FPlacementBounds := TRect.Empty;
  FPreviewFrame := FViewport.Frame(MusicStudioFitFrameRect(FPreview.ClientRect, FFrameWidth, FFrameHeight));
  Surface.Brush.Color := clBlack;
  Surface.FillRect(FPreviewFrame);
  if not FBackground.Empty then
    Surface.StretchDraw(FPreviewFrame, FBackground);

  try
    if FImageDirty then
    begin
      FImageDirty := False;
      FImageReady := False;
      Seconds := StrToFloatDef(FTime.Text, 0);
      if IsNan(Seconds) or IsInfinite(Seconds) then Seconds := 0;
      PreviewKey := '';
      if FPreviewMouth.ItemIndex = 1 then PreviewKey := FLayerKey;
      FImageReady := FScene.Render(FImage,Seconds,FLiveSlot,PreviewKey,FLiveStep,nil,FPreviewSeconds);
    end;
    if FImageReady then
    begin
      Target := FScene.Placement(FPreviewFrame, FFrameWidth, FFrameHeight);
      FPlacementBounds := Target;
      Blend.BlendOp := AC_SRC_OVER;
      Blend.BlendFlags := 0;
      Blend.SourceConstantAlpha := 255;
      Blend.AlphaFormat := AC_SRC_ALPHA;
      PreviewDC := Surface.Handle;
      SavedDC := SaveDC(PreviewDC);
      if SavedDC = 0 then Exit;
      try
        IntersectClipRect(PreviewDC, FPreviewFrame.Left, FPreviewFrame.Top,
          FPreviewFrame.Right, FPreviewFrame.Bottom);
        Winapi.Windows.AlphaBlend(PreviewDC, Target.Left, Target.Top,
          Target.Width, Target.Height, FImage.Canvas.Handle, 0, 0, FImage.Width, FImage.Height, Blend);
      finally
        RestoreDC(PreviewDC, SavedDC);
      end;
      PaintPlacement(Surface);
    end;
  except
    on E: Exception do FStatus.Caption := E.Message;
  end;
  // 背景・PSD・編集枠が揃ってから一度だけ画面へ転送する。
  FPreview.Canvas.Draw(0, 0, FPreviewBuffer);
end;

procedure TFormLipSyncSettings.PreviewWheel(Sender: TObject; Shift: TShiftState;
  Delta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  P: TPoint;
begin
  if Handled or (FPreview = nil) then Exit;
  P := FPreview.ScreenToClient(MousePos);
  if not FPreview.ClientRect.Contains(P) then Exit;
  Handled := True;
  if FDragging or FPanning then Exit;
  FViewport.ZoomAt(MusicStudioFitFrameRect(FPreview.ClientRect,FFrameWidth,FFrameHeight),P,Delta);
  FPreview.Invalidate;
end;

function TFormLipSyncSettings.HitPlacement(X, Y: Integer): Integer;
var
  P: TPoint;
begin
  P := Point(X,Y);
  if FPlacementSelected then
  begin
    Result := LipSyncGripAt(FPlacementBounds,P,Max(3,MulDiv(5,CurrentPPI,96)));
    if (Result <> 5) or FPreviewFrame.Contains(P) then Exit;
  end;
  Result := 0;
  if FPlacementBounds.Contains(P) and FPreviewFrame.Contains(P) then Result := 5;
end;

procedure TFormLipSyncSettings.PaintPlacement(Canvas: TCanvas);
begin
  if FPlacementSelected then
    DrawLipSyncPlacement(Canvas,FPlacementBounds,Max(3,MulDiv(5,CurrentPPI,96)));
end;

procedure TFormLipSyncSettings.PreviewMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if not (Button in [mbLeft, mbMiddle]) then Exit;
  FGrip := HitPlacement(X, Y);
  if (Button = mbMiddle) or (FGrip = 0) then
  begin
    if Button = mbLeft then FPlacementSelected := False;
    if ssDouble in Shift then
      FViewport.Reset
    else
    begin
      FPanning := True;
      FPanMouse := Point(X,Y);
      FPreview.Cursor := crSizeAll;
      TPreviewPaintBox(FPreview).MouseCapture := True;
    end;
    FPreview.Invalidate;
    Exit;
  end;
  FPlacementSelected := True;
  FPreview.Invalidate;
  FDragOrigin := Point(X, Y);
  FDragBounds := FPlacementBounds;
  FDragFrame := FPreviewFrame;
  FDragTransform := FScene.TransformFor(FFrameWidth, FFrameHeight);
  FDragging := True;
  TPreviewPaintBox(FPreview).MouseCapture := True;
end;

procedure TFormLipSyncSettings.PreviewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  Transform: TMusicStudioPsdTransform;
begin
  if FPanning then
  begin
    if GetCaptureControl = FPreview then
    begin
      FViewport.PanBy(X-FPanMouse.X,Y-FPanMouse.Y);
      FPanMouse := Point(X,Y);
      FPreview.Invalidate;
    end
    else
    begin
      FPanning := False;
      FPreview.Cursor := crDefault;
    end;
    Exit;
  end;
  if not FDragging then
  begin
    case HitPlacement(X, Y) of
      1, 4: FPreview.Cursor := crSizeNWSE;
      2, 3: FPreview.Cursor := crSizeNESW;
      5: FPreview.Cursor := crSizeAll;
    else
      FPreview.Cursor := crDefault;
    end;
    Exit;
  end;

  Transform := LipSyncDragPlacement(FDragTransform,FDragBounds,FDragFrame,
    FFrameWidth,FFrameHeight,FGrip,X-FDragOrigin.X,Y-FDragOrigin.Y);
  FLoading := True;
  try
    ShowTransform(Transform);
  finally
    FLoading := False;
  end;
  Change(FX);
end;

procedure TFormLipSyncSettings.PreviewMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if FPanning and (Button in [mbLeft,mbMiddle]) then
  begin
    PreviewMouseMove(Sender,Shift,X,Y);
    FPanning := False;
    FPreview.Cursor := crDefault;
    TPreviewPaintBox(FPreview).MouseCapture := False;
    Exit;
  end;
  if (Button <> mbLeft) or not FDragging then Exit;
  PreviewMouseMove(Sender, Shift, X, Y);
  FDragging := False;
  TPreviewPaintBox(FPreview).MouseCapture := False;
end;

procedure TFormLipSyncSettings.SetEmbedded;
begin
  FEmbedded := True;
  FMusic.Visible := False;
  FMusicLabel.Visible := False;
  FOKButton.Visible := False;
  FCancelButton.Visible := False;
end;

procedure TFormLipSyncSettings.Apply(Sender: TObject);
begin
  if CommitSettings then ModalResult := mrOk;
end;

function TFormLipSyncSettings.CommitSettings: Boolean;
var
  PsdPath, MusicPath: string;
begin
  Result := False;
  try
    PsdPath := Trim(FPsd.Text);
    MusicPath := Trim(FMusic.Text);
    if (PsdPath <> '') and
      (not SameText(ExtractFileExt(PsdPath), '.psd') or not FileExists(PsdPath)) then
      raise Exception.Create('有効な PSD ファイルを指定してください。');
    if not FEmbedded and (MusicPath <> '') and
      ((LipSyncMode(MusicPath) = lmNone) or not FileExists(MusicPath)) then
      raise Exception.Create('有効な音楽ファイルを指定してください。');
    UpdateConfig;
    FScene.Configure(PsdPath, MusicPath, FConfig.ToJSON);
    if (PsdPath <> '') and not FScene.Document.Loaded then
      raise Exception.Create(FScene.Document.LastError);
    FApply(PsdPath, MusicPath, FConfig.ToJSON);
    Result := True;
  except
    on E: Exception do MessageDlg(E.Message, mtError, [mbOK], 0);
  end;
end;

end.
