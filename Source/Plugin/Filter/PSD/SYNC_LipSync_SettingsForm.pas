unit SYNC_LipSync_SettingsForm;

// PSD単体の試写と、目パチ・口パク差分の割り当てを担当する。

interface

uses
  Winapi.Messages, System.Classes, System.JSON, System.Types,
  Vcl.Controls, Vcl.Forms, Vcl.Graphics, Vcl.ExtCtrls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.Menus,
  SYNC_LipSync_Scene, SYNC_LipSync_PreviewViewport;

type
  TLipSyncApply = reference to procedure(const PsdPath, MusicPath, JSON: string);

  // 各項目の値だけを無効化する。更新中もコントロールの寸法は変えない。
  TPreviewSampleStatus = class(TCustomControl)
  private
    FValues: array[0..2] of string;
    function FieldRect(Index: Integer): TRect;
    procedure SetValue(Index: Integer; const Value: string);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetValues(const Vowel, Opening, Eye: string);
  end;

  TPreviewState = (psLayer, psPaused, psPlaying);

  TFormLipSyncSettings = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FPsd, FMusic: TEdit;
    FPreviewPanel, FAssetPanel, FOptionsPanel: TPanel;
    FSplitter: TSplitter;
    FLayers: TTreeView;
    FLayerMenu: TPopupMenu;
    FLayerKey, FTreePath: string;
    FPreviewMode: TComboBox;
    FThreshold, FTime, FBlinkSpeed, FMouthSpeed: TTrackBar;
    FThresholdValue, FTimeValue, FBlinkValue, FMouthValue: TLabel;
    FPlayButton: TButton;
    FPreviewState: TPreviewState;
    FUpdatingTime: Boolean;
    FLiveState: TPreviewSampleStatus;
    FPreviewTick: UInt64;
    FPreviewSeconds: Double;
    FLiveSlot, FLiveStep, FLastEye: Integer;
    FSmooth: TCheckBox;
    FStatus: TLabel;
    FPreview: TPaintBox;
    FTimer: TTimer;
    FConfig: TJSONObject;
    FScene: TLipSyncScene;
    FImage, FPreviewBuffer: TBitmap;
    FImageDirty, FImageReady: Boolean;
    FLastMusicStatus: string;
    FPanMouse: TPoint;
    FViewport: TLipSyncPreviewViewport;
    FPanning: Boolean;
    FApply: TLipSyncApply;
    FLoading: Boolean;
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
    procedure UpdateSliderValues;
    function PreviewDuration: Double;
    function PreviewTime(Duration: Double): Double;
    procedure TogglePreview(Sender: TObject);
    procedure SetPreviewState(State: TPreviewState);
    procedure PreviewModeChanged(Sender: TObject);
    procedure SeekPreview(Sender: TObject);
    function MaxPreviewWidth: Integer;
    procedure LimitSplitter(Sender: TObject; var NewSize: Integer; var Accept: Boolean);
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
    procedure LayerFocused(Sender: TObject);
    procedure LayerMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X,Y: Integer);
    procedure DrawLayerItem(Sender: TCustomTreeView; Node: TTreeNode;
      State: TCustomDrawState; Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
    procedure LayerContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure AssignLayer(Sender: TObject);
    procedure DrawPreviewItem(Control: TWinControl; Index: Integer;
      Rect: TRect; State: TOwnerDrawState);
    procedure DrawMenuItem(Sender: TObject; ACanvas: TCanvas; ARect: TRect;
      Selected: Boolean);
    procedure UpdateConfig;
    function PreviewFit: TRect;
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure Resize; override;
  public
    procedure SetEmbedded;
    // 素材と編集中の差分を検証し、成功時だけ呼出側のモデルへ反映する。
    function CommitSettings: Boolean;
    // 素材と設定を読み込み、確定時に ApplySettings へ返す。
    procedure LoadSettings(const PsdPath, MusicPath, JSON: string; const ApplySettings: TLipSyncApply);
  end;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI, System.SysUtils, System.Math, System.UITypes,
  Winapi.UxTheme, Winapi.CommCtrl, System.Generics.Collections,
  Vcl.Dialogs, SYNC_MusicStudio_PsdLayers, SYNC_MusicStudio_PsdLayerConfig,
  SYNC_MusicStudio_HostBackground,
  SYNC_MusicStudio_DarkTheme;

{$R *.dfm}

type
  TPreviewPaintBox = class(TPaintBox)
  public
    constructor Create(AOwner: TComponent); override;
  end;
  TDarkTrackBar = class(TTrackBar)
  private
    procedure CNNotify(var Msg: TWMNotify); message CN_NOTIFY;
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure PaintTrack(DC: HDC);
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

procedure TDarkTrackBar.CNNotify(var Msg: TWMNotify);
var
  Draw: PNMCustomDraw;
begin
  if Msg.NMHdr.code=NM_CUSTOMDRAW then
  begin
    Draw := PNMCustomDraw(Msg.NMHdr);
    if Draw.dwDrawStage=CDDS_PREPAINT then
    begin
      PaintTrack(Draw.hdc);
      Msg.Result := CDRF_SKIPDEFAULT;
      Exit;
    end;
  end;
  inherited;
end;

procedure TDarkTrackBar.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1;
end;

procedure TDarkTrackBar.PaintTrack(DC: HDC);
var
  Channel, Thumb, Progress, FocusBounds: TRect;
  Brush: HBRUSH;
  CenterY, HalfHeight, ThumbX: Integer;

  procedure Fill(const Bounds: TRect; Color: TColor);
  begin
    SetDCBrushColor(DC,ColorToRGB(Color));
    Winapi.Windows.FillRect(DC,Bounds,Brush);
  end;
begin
  Brush := GetStockObject(DC_BRUSH);
  Fill(ClientRect,SYNC_MUSIC_STUDIO_DARK_PANEL_COLOR);
  SendMessage(Handle,TBM_GETCHANNELRECT,0,LPARAM(@Channel));
  SendMessage(Handle,TBM_GETTHUMBRECT,0,LPARAM(@Thumb));
  CenterY := (Thumb.Top+Thumb.Bottom) div 2;
  ThumbX := (Thumb.Left+Thumb.Right) div 2;
  HalfHeight := System.Math.Max(1,MulDiv(2,CurrentPPI,96));
  Channel := Rect(System.Math.Min(Channel.Left,ThumbX),CenterY-HalfHeight,
    System.Math.Max(Channel.Right,ThumbX),CenterY+HalfHeight);
  Fill(Channel,$00505050);
  Progress := Channel;
  Progress.Right := ThumbX;
  Fill(Progress,$008F603A);
  InflateRect(Thumb,-MulDiv(1,CurrentPPI,96),-MulDiv(2,CurrentPPI,96));
  Fill(Thumb,$00E2AC78);
  if Focused and (Perform(WM_QUERYUISTATE,0,0) and UISF_HIDEFOCUS=0) then
  begin
    FocusBounds := ClientRect;
    InflateRect(FocusBounds,-1,-1);
    DrawFocusRect(DC,FocusBounds);
  end;
end;

constructor TPreviewSampleStatus.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle+[csOpaque];
end;

function TPreviewSampleStatus.FieldRect(Index: Integer): TRect;
begin
  Result := Rect(ClientWidth*Index div Length(FValues),0,
    ClientWidth*(Index+1) div Length(FValues),ClientHeight);
end;

procedure TPreviewSampleStatus.SetValue(Index: Integer; const Value: string);
var
  Bounds: TRect;
begin
  if FValues[Index]=Value then Exit;
  FValues[Index] := Value;
  if HandleAllocated then
  begin
    Bounds := FieldRect(Index);
    Bounds.Top := Bounds.Height div 2;
    InvalidateRect(Handle,@Bounds,False);
  end;
end;

procedure TPreviewSampleStatus.SetValues(const Vowel, Opening, Eye: string);
begin
  SetValue(0,Vowel);
  SetValue(1,Opening);
  SetValue(2,Eye);
end;

procedure TPreviewSampleStatus.Paint;
const
  Titles: array[0..2] of string = ('音素','開閉','目パチ');
var
  I, Middle: Integer;
  Clip, Bounds: TRect;

  procedure PaintText(const Value: string; const TextBounds: TRect);
  var
    TextRect: TRect;
    Text: string;
  begin
    if not IntersectRect(TextRect,Clip,TextBounds) then Exit;
    TextRect := TextBounds;
    Inc(TextRect.Left,MulDiv(8,CurrentPPI,96));
    Text := Value;
    Canvas.TextRect(TextRect,Text,[tfSingleLine,tfVerticalCenter,tfEndEllipsis,tfNoPrefix]);
  end;
begin
  Clip := Canvas.ClipRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := SYNC_MUSIC_STUDIO_DARK_PANEL_COLOR;
  Canvas.FillRect(Clip);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Assign(Font);
  Middle := ClientHeight div 2;
  for I := Low(FValues) to High(FValues) do
  begin
    Bounds := FieldRect(I);
    Bounds.Bottom := Middle;
    Canvas.Font.Color := $00AAAAAA;
    PaintText(Titles[I],Bounds);
    Bounds.Top := Middle;
    Bounds.Bottom := ClientHeight;
    Canvas.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
    PaintText(FValues[I],Bounds);
  end;
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
  PREVIEW_OPEN = 1;
  PREVIEW_MUSIC = 2;
  EYE_MENU_TAG = 100;

procedure TFormLipSyncSettings.FormCreate(Sender: TObject);
var
  Panel, Editor, TreePanel, PlaybackPanel: TPanel;
  Sliders: TGridPanel;
  TreeTitle: TLabel;
  I, Slot, RowHeight, SliderRowHeight, Inset: Integer;
  Button: TButton;
  MenuItem, Category: TMenuItem;
  Eye: TLipSyncEye;
  function Px(Value: Integer): Integer;
  begin
    Result := MulDiv(Value,PixelsPerInch,96);
  end;
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
    Result.SetBounds(X,Y,Width,RowHeight-Px(5));
    Result.OnChange := OnChange;
    ApplySyncMusicStudioDarkEdit(Result);
  end;
  function ButtonAt(const Caption: string; X, Y: Integer; Click: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Panel;
    Result.SetBounds(X,Y,Px(86),RowHeight-Px(5));
    Result.Caption := Caption;
    Result.OnClick := Click;
    ApplySyncMusicStudioDarkButton(Result);
  end;
  function CheckAt(const Caption: string; X, Y, Width: Integer): TCheckBox;
  begin
    Result := TDarkCheckBox.Create(Self);
    Result.Parent := Panel;
    Result.SetBounds(X,Y,Width,RowHeight-Px(5));
    Result.Caption := Caption;
    Result.OnClick := Change;
  end;
  function ComboAt(X, Y, Width: Integer): TComboBox;
  begin
    Result := TComboBox.Create(Self);
    Result.Parent := Panel;
    ApplySyncMusicStudioDarkComboBox(Result,DrawPreviewItem);
    Result.ItemHeight := Canvas.TextHeight('国')+Px(4);
    Result.SetBounds(X,Y,Width,RowHeight-Px(5));
    Result.OnChange := PreviewModeChanged;
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
  function SliderCell(const Caption, LongestValue: string; MinValue, MaxValue, InitialValue: Integer;
    OnChange: TNotifyEvent; out ValueLabel: TLabel): TTrackBar;
  var
    Cell, Header: TPanel;
    Title: TLabel;
  begin
    Cell := TPanel.Create(Self);
    Cell.Parent := Sliders;
    Cell.Align := alClient;
    Cell.BevelOuter := bvNone;
    Cell.Padding.Left := Inset;
    Cell.Padding.Right := Inset;
    ApplySyncMusicStudioDarkPanel(Cell);
    Header := TPanel.Create(Self);
    Header.Parent := Cell;
    Header.Align := alTop;
    Header.Height := Canvas.TextHeight('国')+Px(2);
    Header.BevelOuter := bvNone;
    ApplySyncMusicStudioDarkPanel(Header);
    ValueLabel := TLabel.Create(Self);
    ValueLabel.Parent := Header;
    ValueLabel.AutoSize := False;
    ValueLabel.Align := alRight;
    ValueLabel.Width := Canvas.TextWidth(LongestValue)+Px(4);
    ValueLabel.Alignment := taRightJustify;
    Title := TLabel.Create(Self);
    Title.Parent := Header;
    Title.AutoSize := False;
    Title.Align := alClient;
    Title.Caption := Caption;

    Result := TDarkTrackBar.Create(Self);
    Result.Parent := Cell;
    Result.Align := alClient;
    Result.ThumbLength := Px(16);
    Result.Min := MinValue;
    Result.Max := MaxValue;
    Result.Position := InitialValue;
    Result.TickStyle := tsNone;
    Result.OnChange := OnChange;
  end;
begin
  ApplySyncMusicStudioDarkForm(Self);
  Canvas.Font.Assign(Font);
  Inset := Px(12);
  RowHeight := Max(Px(30),Canvas.TextHeight('国')+Px(11));
  SliderRowHeight := RowHeight+Px(7);
  FScene := TLipSyncScene.Create;
  FImage := Vcl.Graphics.TBitmap.Create;
  FPreviewBuffer := Vcl.Graphics.TBitmap.Create;
  FPreviewBuffer.PixelFormat := pf32bit;
  FImageDirty := True;
  FPreviewPanel := TPanel.Create(Self);
  FPreviewPanel.Parent := Self;
  FPreviewPanel.Align := alLeft;
  FPreviewPanel.Width := ClientWidth div 2;
  FPreviewPanel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(FPreviewPanel);

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Left := FPreviewPanel.Width;
  FSplitter.Align := alLeft;
  FSplitter.Width := Px(7);
  FSplitter.MinSize := Px(144);
  FSplitter.OnCanResize := LimitSplitter;
  FSplitter.AutoSnap := False;
  FSplitter.ResizeStyle := rsUpdate;
  FSplitter.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;

  Editor := TPanel.Create(Self);
  Editor.Parent := Self;
  Editor.Align := alClient;
  Editor.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(Editor);

  FAssetPanel := TPanel.Create(Self);
  FAssetPanel.Parent := Editor;
  FAssetPanel.Align := alTop;
  FAssetPanel.Height := 3*RowHeight+Px(12);
  FAssetPanel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(FAssetPanel);
  Panel := FAssetPanel;
  LabelAt('PSD（ドロップして変更）',Inset,Px(6));
  FPsd := EditAt(Inset,RowHeight,Panel.ClientWidth-2*Inset,nil);
  FPsd.Anchors := [akLeft,akTop,akRight];
  FPsd.ReadOnly := True;
  FPsd.TabStop := False;
  FMusicLabel := LabelAt('音楽ファイル（ドロップ）',Inset,2*RowHeight+Px(2));
  FMusic := EditAt(Inset,3*RowHeight-Px(6),Panel.ClientWidth-2*Inset,nil);
  FAssetPanel.Height := FMusic.Top+FMusic.Height+Px(6);
  FMusic.Anchors := [akLeft,akTop,akRight];
  FMusic.ReadOnly := True;
  FMusic.TabStop := False;

  TreePanel := TPanel.Create(Self);
  TreePanel.Parent := Editor;
  TreePanel.Align := alClient;
  TreePanel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(TreePanel);
  TreeTitle := TLabel.Create(Self);
  TreeTitle.Parent := TreePanel;
  TreeTitle.Align := alTop;
  TreeTitle.AlignWithMargins := True;
  TreeTitle.Margins.Left := Inset;
  TreeTitle.Caption := 'PSD レイヤー  ・  選択で試写 / 右クリックで割当';
  FLayers := TTreeView.Create(Self);
  FLayers.Parent := TreePanel;
  FLayers.Align := alClient;
  FLayers.AlignWithMargins := True;
  FLayers.Margins.Left := Inset;
  FLayers.Margins.Right := Inset;
  FLayers.ReadOnly := True;
  FLayers.HideSelection := False;
  FLayers.Color := SYNC_MUSIC_STUDIO_DARK_CONTROL_COLOR;
  FLayers.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  FLayers.StyleElements := FLayers.StyleElements - [seClient];
  FLayers.OnChange := LayerChanged;
  FLayers.OnEnter := LayerFocused;
  FLayers.OnMouseDown := LayerMouseDown;
  FLayers.OnAdvancedCustomDrawItem := DrawLayerItem;
  FLayers.OnContextPopup := LayerContextPopup;
  SetWindowTheme(FLayers.Handle, 'DarkMode_Explorer', nil);

  FLayerMenu := TPopupMenu.Create(Self);
  FLayerMenu.OwnerDraw := True;
  Category := MenuBranch('目パチ');
  for Eye := Low(Eye) to High(Eye) do
    AddAssignment(Category,LIP_SYNC_EYE_NAMES[Eye],EYE_MENU_TAG+Ord(Eye));
  Category := MenuBranch('口パク（開閉）');
  for I := High(LIP_SYNC_OPENING_SLOTS) downto Low(LIP_SYNC_OPENING_SLOTS) do
  begin
    Slot := LIP_SYNC_OPENING_SLOTS[I];
    AddAssignment(Category,LIP_SYNC_SLOT_NAMES[Slot],Slot);
  end;
  Category := MenuBranch('口パク（ソング）');
  AddAssignment(Category,LIP_SYNC_SLOT_NAMES[0],0);
  for I := 1 to 6 do AddAssignment(Category,LIP_SYNC_SLOT_NAMES[I],I);
  MenuItem := TMenuItem.Create(FLayerMenu);
  MenuItem.Caption := '-';
  FLayerMenu.Items.Add(MenuItem);
  AddAssignment(FLayerMenu.Items,'このレイヤーの割当を解除',-1);

  FOptionsPanel := TPanel.Create(Self);
  FOptionsPanel.Parent := Editor;
  FOptionsPanel.Align := alBottom;
  FOptionsPanel.Height := 2*SliderRowHeight+2*RowHeight+Px(8);
  FOptionsPanel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(FOptionsPanel);
  Sliders := TGridPanel.Create(Self);
  Sliders.Parent := FOptionsPanel;
  Sliders.Align := alTop;
  Sliders.Height := 2*SliderRowHeight;
  Sliders.BevelOuter := bvNone;
  Sliders.ParentBackground := False;
  Sliders.Color := SYNC_MUSIC_STUDIO_DARK_PANEL_COLOR;
  Sliders.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  for I := 0 to 1 do
  begin
    Sliders.ColumnCollection[I].SizeStyle := ssPercent;
    Sliders.ColumnCollection[I].Value := 50;
    Sliders.RowCollection[I].SizeStyle := ssPercent;
    Sliders.RowCollection[I].Value := 50;
  end;
  FThreshold := SliderCell('音量しきい値','99.0%',0,990,80,Change,FThresholdValue);
  FThreshold.LineSize := 10;
  FThreshold.PageSize := 100;
  FTime := SliderCell('試写時刻','0000:00',0,1000,0,SeekPreview,FTimeValue);
  FTime.PageSize := 50;
  FBlinkSpeed := SliderCell('目パチ速度','2.0倍',5,20,10,Change,FBlinkValue);
  FMouthSpeed := SliderCell('口パク速度','2.0倍',5,20,10,Change,FMouthValue);

  Panel := FOptionsPanel;
  FSmooth := CheckAt('口パクの開閉を滑らかにする',Inset,Sliders.Height+Px(2),Panel.ClientWidth-2*Inset);
  FSmooth.Anchors := [akLeft,akTop,akRight];

  Button := ButtonAt('OK',Panel.ClientWidth-Px(194),Sliders.Height+RowHeight,Apply);
  Button.Anchors := [akTop,akRight];
  FOKButton := Button;
  Button.Default := True;
  Button := ButtonAt('キャンセル',Panel.ClientWidth-Px(98),Sliders.Height+RowHeight,nil);
  Button.Anchors := [akTop,akRight];
  FCancelButton := Button;
  Button.Cancel := True;
  Button.ModalResult := mrCancel;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FPreviewPanel;
  FStatus.Align := alBottom;
  FStatus.AutoSize := False;
  FStatus.Height := 2*Canvas.TextHeight('国')+Px(6);
  FStatus.WordWrap := True;
  FLiveState := TPreviewSampleStatus.Create(Self);
  FLiveState.Parent := FPreviewPanel;
  FLiveState.Align := alBottom;
  FLiveState.Height := 2*Canvas.TextHeight('国')+Px(8);

  PlaybackPanel := TPanel.Create(Self);
  PlaybackPanel.Parent := FPreviewPanel;
  PlaybackPanel.Align := alBottom;
  PlaybackPanel.Height := RowHeight+Px(5);
  PlaybackPanel.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(PlaybackPanel);
  Panel := PlaybackPanel;
  FPlayButton := ButtonAt('▶',Px(6),Px(3),TogglePreview);
  FPlayButton.Width := Px(30);
  FPlayButton.Font.Name := 'Segoe UI Symbol';
  FPlayButton.ShowHint := True;
  FPlayButton.Hint := '自動試写を再生';
  FPreviewMode := ComboAt(Px(42),Px(3),Max(Px(68),Panel.ClientWidth-Px(48)));
  FPreviewMode.Anchors := [akLeft,akTop,akRight];
  FPreviewMode.Items.Add('ソング');
  FPreviewMode.Items.Add('開閉');
  FPreviewMode.Items.Add('素材同期');
  FPreviewMode.ItemIndex := 0;
  FPreviewMode.ShowHint := True;
  FPreviewMode.Hint := '自動試写の種類';

  FPreview := TPreviewPaintBox.Create(Self);
  FPreview.Parent := FPreviewPanel;
  FPreview.Align := alClient;
  FPreview.OnPaint := PaintPreview;
  FPreview.OnMouseDown := PreviewMouseDown;
  FPreview.OnMouseMove := PreviewMouseMove;
  FPreview.OnMouseUp := PreviewMouseUp;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 50;
  FLastEye := -1;
  FLiveSlot := -1;
  FLiveStep := -1;
  FTimer.OnTimer := Tick;
  OnMouseWheel := PreviewWheel;
  Resize;
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
end;

procedure TFormLipSyncSettings.LoadSettings(const PsdPath, MusicPath, JSON: string;
  const ApplySettings: TLipSyncApply);
begin
  FLoading := True;
  try
    FApply := ApplySettings;
    FreeAndNil(FConfig);
    FConfig := ParseMusicStudioPsdConfig(JSON);
    FPsd.Text := PsdPath;
    FMusic.Text := MusicPath;
    FThreshold.Position := Round(10*LipSyncNumber(FConfig,'threshold',8,0,99));
    FSmooth.Checked := MusicStudioAnimateMouthSize(FConfig);
    FBlinkSpeed.Position := Round(10*LipSyncNumber(FConfig,'blinkSpeed',1,0.5,2));
    FMouthSpeed.Position := Round(10*LipSyncNumber(FConfig,'sampleMouthSpeed',1,0.5,2));
  finally
    FLoading := False;
  end;
  UpdateSliderValues;
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
  FViewport.Reset;
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
  Keys: array[Low(LIP_SYNC_SLOT_NAMES)..High(LIP_SYNC_SLOT_NAMES)] of string;
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

procedure TFormLipSyncSettings.DrawLayerItem(Sender: TCustomTreeView; Node: TTreeNode;
  State: TCustomDrawState; Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
var
  Bounds: TRect;
  Text: string;
begin
  if (Stage<>cdPostPaint) or not Node.Selected then Exit;
  // テーマ側の選択文字色に依存せず、文字の範囲だけを描き直す。
  Bounds := Node.DisplayRect(True);
  if Bounds.IsEmpty then Exit;
  Sender.Canvas.Brush.Style := bsSolid;
  Sender.Canvas.Brush.Color := $00664729;
  Sender.Canvas.FillRect(Bounds);
  Sender.Canvas.Font.Color := SYNC_MUSIC_STUDIO_DARK_TEXT_COLOR;
  Sender.Canvas.Brush.Style := bsClear;
  Text := Node.Text;
  Sender.Canvas.TextRect(Bounds,Text,[tfSingleLine,tfVerticalCenter,tfEndEllipsis,tfNoPrefix]);
  if Sender.Focused then DrawFocusRect(Sender.Canvas.Handle,Bounds);
end;

procedure TFormLipSyncSettings.LayerChanged(Sender: TObject; Node: TTreeNode);
var
  Key: string;
begin
  if FLoading then Exit;
  Key := '';
  if Node<>nil then Key := FScene.Document.Layers[NativeInt(Node.Data)-1].Key;
  if (FPreviewState=psLayer) and (FLayerKey=Key) then Exit;
  FLayerKey := Key;
  SetPreviewState(psLayer);
end;

procedure TFormLipSyncSettings.LayerFocused(Sender: TObject);
begin
  LayerChanged(Sender,FLayers.Selected);
end;

procedure TFormLipSyncSettings.LayerMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X,Y: Integer);
var
  Node: TTreeNode;
begin
  if not (Button in [mbLeft,mbRight]) then Exit;
  Node := FLayers.GetNodeAt(X,Y);
  if Node=nil then Node := FLayers.Selected;
  LayerChanged(Sender,Node);
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
  if Slot>=EYE_MENU_TAG then
    AssignLipSyncEye(FConfig,TLipSyncEye(Slot-EYE_MENU_TAG),Key)
  else if Slot>=0 then
    AssignLipSyncLayer(FConfig,Slot,Key)
  else
  begin
    for Slot := 0 to High(LIP_SYNC_SLOT_NAMES) do
      if LipSyncLayer(FConfig,Slot)=Key then AssignLipSyncLayer(FConfig,Slot,'');
    for Eye := Low(Eye) to High(Eye) do
      if LipSyncEyeLayer(FConfig,Eye)=Key then AssignLipSyncEye(FConfig,Eye,'');
  end;
  RefreshLayerCaptions;
  LayerChanged(FLayers,FLayers.Selected);
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
      FPreviewState := psLayer;
      FPreviewSeconds := 0;
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

procedure TFormLipSyncSettings.UpdateConfig;
begin
  MusicStudioSetJsonBoolean(FConfig, 'animateMouthSize', FSmooth.Checked);
  FConfig.RemovePair('blinkSpeed').Free;
  FConfig.AddPair('blinkSpeed',TJSONNumber.Create(FBlinkSpeed.Position/10));
  FConfig.RemovePair('sampleMouthSpeed').Free;
  FConfig.AddPair('sampleMouthSpeed',TJSONNumber.Create(FMouthSpeed.Position/10));
end;

procedure TFormLipSyncSettings.Change(Sender: TObject);
begin
  if Sender is TTrackBar then TTrackBar(Sender).Invalidate;
  if FLoading or (FConfig = nil) or (FPreview = nil) then Exit;
  try
    if Sender=FThreshold then
    begin
      FConfig.RemovePair('threshold').Free;
      FConfig.AddPair('threshold',TJSONNumber.Create(FThreshold.Position/10));
    end;
    UpdateConfig;
    FScene.Configure(Trim(FPsd.Text), Trim(FMusic.Text), FConfig.ToJSON);
    UpdateSliderValues;
    Tick(nil);
    FImageDirty := True;
    FPreview.Invalidate;
  except
    on E: Exception do FStatus.Caption := E.Message;
  end;
end;

procedure TFormLipSyncSettings.UpdateSliderValues;
begin
  FThresholdValue.Caption := FormatFloat('0.0',FThreshold.Position/10)+'%';
  FBlinkValue.Caption := FormatFloat('0.0',FBlinkSpeed.Position/10)+'倍';
  FMouthValue.Caption := FormatFloat('0.0',FMouthSpeed.Position/10)+'倍';
end;

function TFormLipSyncSettings.PreviewDuration: Double;
begin
  if FPreviewMode.ItemIndex=PREVIEW_MUSIC then Result := FScene.MusicDuration
  else Result := LIP_SYNC_SAMPLE_SECONDS/(FMouthSpeed.Position/10);
end;

function TFormLipSyncSettings.PreviewTime(Duration: Double): Double;
begin
  if Duration<=0 then Exit(0);
  // 時刻スライダーは1周分を表示する。瞬きには通算の時刻を使う。
  Result := FPreviewSeconds;
  if Result>Duration then Result := Frac(Result/Duration)*Duration;
end;

procedure TFormLipSyncSettings.SetPreviewState(State: TPreviewState);
begin
  FPreviewState := State;
  FPreviewTick := GetTickCount64;
  FImageDirty := True;
  Tick(nil);
  FPreview.Invalidate;
end;

procedure TFormLipSyncSettings.TogglePreview(Sender: TObject);
begin
  if FPreviewState=psPlaying then SetPreviewState(psPaused)
  else if FPlayButton.Enabled then SetPreviewState(psPlaying);
end;

procedure TFormLipSyncSettings.PreviewModeChanged(Sender: TObject);
begin
  if FLoading or (FConfig=nil) then Exit;
  FPreviewSeconds := 0;
  if (FPreviewState=psPlaying) and (PreviewDuration<=0) then SetPreviewState(psPaused)
  else SetPreviewState(FPreviewState);
end;

procedure TFormLipSyncSettings.SeekPreview(Sender: TObject);
begin
  FTime.Invalidate;
  if FLoading or FUpdatingTime or (FConfig=nil) or not FTime.Enabled then Exit;
  FPreviewSeconds := FTime.Position/FTime.Max*PreviewDuration;
  SetPreviewState(psPaused);
end;

function TFormLipSyncSettings.UpdateLiveSample: Boolean;
var
  Slot, SongSlot, Opening, Step, Eye: Integer;
  VowelText, EyeText: string;
begin
  Eye := -1;
  EyeText := '未割当';
  Slot := 0;
  Step := High(LIP_SYNC_OPENING_SLOTS);
  SongSlot := 0;
  Opening := 0;
  if FPreviewState=psLayer then FLiveState.SetValues('—','—','—')
  else
  begin
    if FScene.HasEyeAssignment then
    begin
      Eye := Ord(FScene.EyeAt(FPreviewSeconds));
      EyeText := LIP_SYNC_EYE_NAMES[TLipSyncEye(Eye)];
    end;
    if FPreviewMode.ItemIndex=PREVIEW_MUSIC then
    begin
      FScene.MouthAt(PreviewTime(PreviewDuration),Slot,Step);
      if Slot in [1..6] then SongSlot := Slot;
      if Slot>0 then Opening := Step;
    end
    else
    begin
      LipSyncSampleMouth(FPreviewSeconds,FMouthSpeed.Position/10,SongSlot,Opening);
      Slot := SongSlot;
      if FPreviewMode.ItemIndex=PREVIEW_OPEN then
      begin
        Slot := LIP_SYNC_OPENING_SLOTS[Opening];
        SongSlot := 0;
      end;
      Step := Max(1,Opening);
    end;
    VowelText := '—';
    if SongSlot>0 then VowelText := LIP_SYNC_SLOT_NAMES[SongSlot];
    FLiveState.SetValues(VowelText,LIP_SYNC_SLOT_NAMES[LIP_SYNC_OPENING_SLOTS[Opening]],EyeText);
  end;
  Result := (Slot<>FLiveSlot) or (FSmooth.Checked and (Slot>0) and (Step<>FLiveStep)) or (Eye<>FLastEye);
  FLiveSlot := Slot;
  FLiveStep := Step;
  FLastEye := Eye;
end;

procedure TFormLipSyncSettings.Tick(Sender: TObject);
var
  NowTick: UInt64;
  Duration, Seconds: Double;
  MusicStatus, StatusText: string;
  Refresh: Boolean;
begin
  Duration := PreviewDuration;
  FTime.Enabled := FScene.Document.Loaded and (Duration>0);
  FPlayButton.Enabled := FTime.Enabled;
  if FPreviewState=psPlaying then
  begin
    NowTick := GetTickCount64;
    FPreviewSeconds := FPreviewSeconds+(NowTick-FPreviewTick)/1000;
    FPreviewTick := NowTick;
    FPlayButton.Caption := '⏸';
    FPlayButton.Hint := '自動試写を一時停止';
  end
  else
  begin
    FPlayButton.Caption := '▶';
    FPlayButton.Hint := '自動試写を再生';
  end;
  if FTime.Enabled then
  begin
    Seconds := PreviewTime(Duration);
    FUpdatingTime := True;
    try
      FTime.Position := Round(FTime.Max*Seconds/Duration);
    finally
      FUpdatingTime := False;
    end;
    if Seconds<60 then FTimeValue.Caption := FormatFloat('0.0',Seconds)+'秒'
    else FTimeValue.Caption := Format('%d:%.2d',[Trunc(Seconds) div 60,Trunc(Seconds) mod 60]);
  end
  else FTimeValue.Caption := '—';

  MusicStatus := '';
  if FPreviewMode.ItemIndex=PREVIEW_MUSIC then MusicStatus := FScene.MusicStatus;
  Refresh := (FPreviewState<>psLayer) and (MusicStatus<>FLastMusicStatus);
  FLastMusicStatus := MusicStatus;
  StatusText := MusicStatus;
  if (Trim(FPsd.Text)<>'') and not FScene.Document.Loaded then StatusText := FScene.Document.LastError;
  if FStatus.Caption<>StatusText then FStatus.Caption := StatusText;
  if ((Sender=nil) or (FPreviewState=psPlaying) or Refresh) and UpdateLiveSample then
    Refresh := True;
  if Refresh then
  begin
    FImageDirty := True;
    FPreview.Invalidate;
  end;
end;

function TFormLipSyncSettings.PreviewFit: TRect;
begin
  Result := MusicStudioFitFrameRect(FPreview.ClientRect,FScene.Document.Width,FScene.Document.Height);
end;

procedure TFormLipSyncSettings.PaintPreview(Sender: TObject);
var
  Seconds: Double;
  Target: TRect;
  Blend: TBlendFunction;
  PreviewKey: string;
  Surface: TCanvas;
begin
  if (FPreview.Width<=0) or (FPreview.Height<=0) then Exit;
  FPreviewBuffer.SetSize(FPreview.Width,FPreview.Height);
  Surface := FPreviewBuffer.Canvas;
  Surface.Brush.Color := SYNC_MUSIC_STUDIO_DARK_BACKGROUND_COLOR;
  Surface.FillRect(FPreview.ClientRect);
  try
    if FImageDirty then
    begin
      FImageDirty := False;
      FImageReady := False;
      Seconds := FPreviewSeconds;
      PreviewKey := '';
      if FPreviewState=psLayer then
      begin
        Seconds := 0;
        PreviewKey := FLayerKey;
      end;
      FImageReady := FScene.Render(FImage,Seconds,FLiveSlot,PreviewKey,FLiveStep,nil,Seconds);
    end;
    if FImageReady then
    begin
      // PSD 原寸の縦横比から表示矩形を求める。作品上の座標と倍率は使わない。
      Target := FViewport.Frame(PreviewFit);
      Surface.Brush.Color := clBlack;
      Surface.FillRect(Target);
      Blend.BlendOp := AC_SRC_OVER;
      Blend.BlendFlags := 0;
      Blend.SourceConstantAlpha := 255;
      Blend.AlphaFormat := AC_SRC_ALPHA;
      Winapi.Windows.AlphaBlend(Surface.Handle,Target.Left,Target.Top,Target.Width,Target.Height,
        FImage.Canvas.Handle,0,0,FImage.Width,FImage.Height,Blend);
    end;
  except
    on E: Exception do FStatus.Caption := E.Message;
  end;
  FPreview.Canvas.Draw(0,0,FPreviewBuffer);
end;

procedure TFormLipSyncSettings.PreviewWheel(Sender: TObject; Shift: TShiftState;
  Delta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  P: TPoint;
begin
  if Handled or (FPreview=nil) then Exit;
  P := FPreview.ScreenToClient(MousePos);
  if not FPreview.ClientRect.Contains(P) then Exit;
  Handled := True;
  if FPanning then Exit;
  FViewport.ZoomAt(PreviewFit,P,Delta);
  FPreview.Invalidate;
end;

procedure TFormLipSyncSettings.PreviewMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if not (Button in [mbLeft,mbMiddle]) then Exit;
  if ssDouble in Shift then
  begin
    FViewport.Reset;
    FPreview.Invalidate;
    Exit;
  end;
  FPanning := True;
  FPanMouse := Point(X,Y);
  FPreview.Cursor := crSizeAll;
  SetCaptureControl(FPreview);
end;

procedure TFormLipSyncSettings.PreviewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if not FPanning then Exit;
  if GetCaptureControl<>FPreview then
  begin
    FPanning := False;
    FPreview.Cursor := crDefault;
    Exit;
  end;
  FViewport.PanBy(X-FPanMouse.X,Y-FPanMouse.Y);
  FPanMouse := Point(X,Y);
  FPreview.Invalidate;
end;

procedure TFormLipSyncSettings.PreviewMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if not FPanning or not (Button in [mbLeft,mbMiddle]) then Exit;
  PreviewMouseMove(Sender,Shift,X,Y);
  FPanning := False;
  FPreview.Cursor := crDefault;
  if GetCaptureControl=FPreview then SetCaptureControl(nil);
end;

function TFormLipSyncSettings.MaxPreviewWidth: Integer;
begin
  Result := Max(0,ClientWidth-FSplitter.Width-MulDiv(300,PixelsPerInch,96));
end;

procedure TFormLipSyncSettings.LimitSplitter(Sender: TObject; var NewSize: Integer;
  var Accept: Boolean);
begin
  NewSize := Min(NewSize,MaxPreviewWidth);
end;

procedure TFormLipSyncSettings.Resize;
begin
  inherited;
  if Assigned(FTime) and Assigned(FSplitter) and (FPreviewPanel.Width>MaxPreviewWidth) then
    FPreviewPanel.Width := MaxPreviewWidth;
end;

procedure TFormLipSyncSettings.SetEmbedded;
begin
  FEmbedded := True;
  FMusic.Visible := False;
  FMusicLabel.Visible := False;
  FOKButton.Visible := False;
  FCancelButton.Visible := False;
  FAssetPanel.Height := FPsd.Top+FPsd.Height+MulDiv(6,PixelsPerInch,96);
  FOptionsPanel.Height := FSmooth.Top+FSmooth.Height+MulDiv(5,PixelsPerInch,96);
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
