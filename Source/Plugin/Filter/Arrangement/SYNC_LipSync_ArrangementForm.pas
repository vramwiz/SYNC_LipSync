unit SYNC_LipSync_ArrangementForm;

// 統合編集の操作、選択・ドラッグの状態、試写の時計と編集画面の切替を管理する。

interface

uses
  Winapi.Messages, System.Classes, System.Types, Vcl.Controls, Vcl.Forms,
  Vcl.Graphics, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Menus,
  SYNC_LipSync_Project, SYNC_LipSync_SettingsForm, SYNC_LipSync_PreviewViewport,
  SYNC_LipSync_TimelineView, SYNC_LipSync_TempoEditor, SYNC_LipSync_EditHistory,
  SYNC_MusicStudio_HostBackground, SYNC_MusicStudio_PreviewPlayback,
  SYNC_MusicStudio_PsdTransform, SYNC_MusicStudio_MotionData;

type
  TLipSyncRangeGrip = (rgCreate, rgMove, rgStart, rgEnd);

  TFormLipSyncArrangement = class(TForm)
  private
    FProject: TLipSyncProject;
    FHistory: TLipSyncEditHistory;
    FTempoEditor: TLipSyncTempoEditor;
    FSelectedTempo: Integer;
    FTempoBeat: Double;
    FApply: TLipSyncApply;
    FReadBackground: TMusicStudioReadBackground;
    FMain, FEditorPanel: TPanel;
    FCloseButton, FPlayButton: TButton;
    FSpaceHeld: Boolean;
    FPsdEditor: TFormLipSyncSettings;
    FTimeline, FStage: TPaintBox;
    FLastBeat: Double;
    FTimelineView: TLipSyncTimelineView;
    FStageView: TLipSyncPreviewViewport;
    FStagePanning: Boolean;
    FStageMouse: TPoint;
    FStageFrame, FSelectedBounds, FEditStartBounds, FEditStartFrame: TRect;
    FStageGrip: Integer;
    FStageOriginal, FStageDraft: TMusicStudioPsdTransform;
    FStatus: TLabel;
    FBPM: TEdit;
    FTimer: TTimer;
    FPlayback: TMusicStudioPlaybackJob;
    FSilentPlaying: Boolean;
    FSilentStart, FSilentEnd: Double;
    FSilentTick: UInt64;
    FMenu, FMotionMenu, FPresentationMenu: TPopupMenu;
    FEffect: TLipSyncEffect;
    FEffectPressed, FEffectChanged: Boolean;
    FEffectGrip: TLipSyncRangeGrip;
    FEffectLane: TLipSyncEffectLane;
    FEffectRow, FEffectDownX: Integer;
    FEffectFrom, FEffectTo, FEffectAnchor: Double;
    FCopyItem, FPasteItem, FDuplicateItem, FDeleteItem, FDeleteCharacterItem: TMenuItem;
    FTempoItem, FUndoItem, FRedoItem, FFlipXItem, FFlipYItem: TMenuItem;
    FSelected: Integer;
    FCharacterHeaderSelected: Boolean;
    FClip, FClipboard: TLipSyncClip;
    FDownX, FDragRow: Integer;
    FDragBeat, FDragOffset, FCursor: Double;
    FDragging, FClipPressed, FAudioReady: Boolean;
    FWidth, FHeight: Integer;
    FSerial, FMissingCheckTick: UInt64;
    FTimelineBuffer, FStageBuffer, FImage, FBackground: TBitmap;
    procedure DropFiles(var Msg: TMessage); message WM_DROPFILES;
    procedure BuildUI;
    procedure PaintTimeline(Sender: TObject);
    procedure PaintStage(Sender: TObject);
    procedure Tick(Sender: TObject);
    procedure Wheel(Sender: TObject; Shift: TShiftState; Delta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure StageMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure StageMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure StageMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure CloseForm(Sender: TObject; var CanClose: Boolean);
    procedure CommitBPM(Sender: TObject);
    procedure CommitTempo(Beat,BPM: Double);
    procedure RecordEdit;
    procedure RestoreEdit(Delta: Integer);
    procedure BPMKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure UpdateClipDrag(Shift: TShiftState; X,Y: Integer);
    procedure UpdateEffectDrag(Shift: TShiftState; X: Integer);
    procedure UpdateTimelineCursor(X,Y: Integer);
    function EffectHit(Row,X: Integer; Lane: TLipSyncEffectLane;
      out Grip: TLipSyncRangeGrip): TLipSyncEffect;
    procedure TimelineMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure TimelineMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure TimelineMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormDeactivate(Sender: TObject);
    procedure Command(Sender: TObject);
    procedure OpenPSD;
    procedure ClosePSD;
    procedure SetEditorVisible(Value: Boolean);
    function MaxTopRow: Integer;
    procedure RefreshView;
    procedure AddMedia(const Path: string; Row: Integer; Beat: Double; Target: TLipSyncClip);
    procedure TogglePlayback;
    procedure StopPlayback(ResetCursor: Boolean);
    procedure UpdatePlaybackButton;
    function SilentPosition: Double;
    procedure SaveProject;
    function IsCharacterRow(Row: Integer): Boolean;
    function IsEffectPosition(Row,Y: Integer; out Lane: TLipSyncEffectLane): Boolean;
    procedure MotionPicked(Sender: TObject);
    procedure PresentationPicked(Sender: TObject);
    function ClipAt(Row, X: Integer): TLipSyncClip;
  protected
    procedure CreateWnd; override;
    procedure DestroyWnd; override;
    procedure Resize; override;
    procedure DoAfterMonitorDpiChanged(OldDPI,NewDPI: Integer); override;
  public
    procedure ScaleForPPI(NewPPI: Integer); override;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // フォームが編集用モデルを所有する。背景取得と保存のコールバックは表示中だけ使用する。
    procedure LoadProject(const PSDPath, MusicPath, JSON: string; Width, Height: Integer;
      const ReadBackground: TMusicStudioReadBackground; const ApplySettings: TLipSyncApply);
  end;

implementation

uses
  Winapi.Windows, Winapi.ShellAPI, System.SysUtils, System.Math, System.UITypes,
  System.Generics.Collections, Vcl.Dialogs,
  SYNC_LipSync_Scene, SYNC_MusicStudio_BeatData,
  SYNC_MusicStudio_DarkTheme, AviUtl2FilterTypes,
  SYNC_LipSync_ExpressionForm, SYNC_LipSync_Presentation;

const
  ROW_HEIGHT = 88;
  PX_PER_BEAT = 46;
  MIN_ROW_HEIGHT = 80;
  MAX_ROW_HEIGHT = 192;

type
  TLipSyncPaintBox = class(TPaintBox)
  public
    constructor Create(AOwner: TComponent); override;
  end;

constructor TLipSyncPaintBox.Create(AOwner: TComponent);
begin
  inherited;
  ControlStyle := ControlStyle + [csOpaque];
end;

constructor TFormLipSyncArrangement.Create(AOwner: TComponent);
var
  WorkArea: TRect;
begin
  inherited CreateNew(AOwner);
  Caption := '口パク - 統合編集';
  Position := poScreenCenter;
  FTimelineView.RowHeight := ROW_HEIGHT;
  FTimelineView.PixelsPerBeat := PX_PER_BEAT;
  FTimelineView.SetDPI(PixelsPerInch);
  WorkArea := Screen.WorkAreaRect;
  ClientWidth := Min(FTimelineView.Px(1260),WorkArea.Width-FTimelineView.Px(20));
  ClientHeight := Min(FTimelineView.Px(760),WorkArea.Height-FTimelineView.Px(46));
  Constraints.MinWidth := Min(FTimelineView.Px(940),WorkArea.Width*9 div 10);
  Constraints.MinHeight := Min(FTimelineView.Px(670),WorkArea.Height*9 div 10);
  Font.Name := 'Yu Gothic UI';
  Font.Height := -FTimelineView.Px(16);
  KeyPreview := True;
  OnKeyDown := FormKey;
  OnKeyUp := FormKeyUp;
  OnDeactivate := FormDeactivate;
  OnMouseWheel := Wheel;
  OnCloseQuery := CloseForm;
  FSelected := -1;
  FSelectedTempo := -1;
  FHistory := TLipSyncEditHistory.Create;
  FTimelineBuffer := Vcl.Graphics.TBitmap.Create;
  FStageBuffer := Vcl.Graphics.TBitmap.Create;
  FBackground := Vcl.Graphics.TBitmap.Create;
  FImage := Vcl.Graphics.TBitmap.Create;
  ApplySyncMusicStudioDarkForm(Self);
  BuildUI;
  Resize;
end;

procedure TFormLipSyncArrangement.Resize;
begin
  inherited;
  if (FStage<>nil) and not (csDestroying in ComponentState) then
    FStage.Height := Min(FTimelineView.Px(232),Max(ClientHeight div 4,ClientHeight-FTimelineView.Px(530)));
end;

procedure TFormLipSyncArrangement.ScaleForPPI(NewPPI: Integer);
begin
  inherited;
  FTimelineView.SetDPI(PixelsPerInch);
  Resize;
  if FProject<>nil then RefreshView;
end;

procedure TFormLipSyncArrangement.DoAfterMonitorDpiChanged(OldDPI,NewDPI: Integer);
begin
  inherited;
  FTimelineView.SetDPI(NewDPI);
  Resize;
  if FProject<>nil then RefreshView;
end;

destructor TFormLipSyncArrangement.Destroy;
begin
  if Assigned(FTimer) then FTimer.Enabled := False;
  FPsdEditor.Free;
  FTempoEditor.Free;
  FPlayback.Free;
  FProject.Free;
  FHistory.Free;
  FClipboard.Free;
  FTimelineBuffer.Free;
  FStageBuffer.Free;
  FBackground.Free;
  FImage.Free;
  inherited;
end;

procedure TFormLipSyncArrangement.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TFormLipSyncArrangement.DestroyWnd;
begin
  DragAcceptFiles(Handle, False);
  inherited;
end;

procedure TFormLipSyncArrangement.BuildUI;
var
  Toolbar, Footer, Center: TPanel;
  Button: TButton;
  LabelText: TLabel;
  Motion: TMusicStudioRhythmType;
  MotionItem, Entrance, ExitMenu, CueItem: TMenuItem;
  Cue: TLipSyncPresentation;
  function Px(Value: Integer): Integer;
  begin
    Result := FTimelineView.Px(Value);
  end;
  procedure Tool(Parent: TPanel; const Text: string; X, W, Tag: Integer);
  begin
    Button := TButton.Create(Self);
    Button.Parent := Parent;
    Button.SetBounds(Px(X),Px(7),Px(W),Px(32));
    Button.Caption := Text;
    Button.Tag := Tag;
    Button.OnClick := Command;
    ApplySyncMusicStudioDarkButton(Button);
  end;
  function MenuItem(const Text: string; Tag: Integer; Key: Word = 0;
    Shift: TShiftState = []): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Caption := Text;
    Result.Tag := Tag;
    if Key <> 0 then Result.ShortCut := ShortCut(Key,Shift);
    Result.OnClick := Command;
    FMenu.Items.Add(Result);
  end;
begin
  Footer := TPanel.Create(Self);
  Footer.Parent := Self;
  Footer.Align := alBottom;
  Footer.Height := Px(47);
  ApplySyncMusicStudioDarkPanel(Footer);
  Tool(Footer,'閉じる',10,178,9);
  FCloseButton := Button;
  FCloseButton.Cancel := True;
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Footer;
  FStatus.AutoSize := False;
  FStatus.AlignWithMargins := True;
  FStatus.Margins.Left := Px(202);
  FStatus.Align := alClient;
  FStatus.Layout := tlCenter;

  FMain := TPanel.Create(Self);
  FMain.Parent := Self;
  FMain.Align := alClient;
  FMain.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(FMain);

  FEditorPanel := TPanel.Create(Self);
  FEditorPanel.Parent := Self;
  FEditorPanel.Align := alClient;
  FEditorPanel.BevelOuter := bvNone;
  FEditorPanel.Visible := False;
  ApplySyncMusicStudioDarkPanel(FEditorPanel);

  Toolbar := TPanel.Create(Self);
  Toolbar.Parent := FMain;
  Toolbar.Align := alTop;
  Toolbar.Height := Px(47);
  ApplySyncMusicStudioDarkPanel(Toolbar);
  Tool(Toolbar,'▶',10,44,3);
  FPlayButton := Button;
  FPlayButton.Font.Name := 'Segoe UI Symbol';
  FPlayButton.ShowHint := True;
  UpdatePlaybackButton;
  Tool(Toolbar,'■',62,44,4);
  Button.Font.Name := 'Segoe UI Symbol';
  Button.Hint := '停止して先頭へ';
  Button.ShowHint := True;
  LabelText := TLabel.Create(Self);
  LabelText.Parent := Toolbar;
  LabelText.SetBounds(Px(124),Px(12),Px(42),Px(24));
  LabelText.Caption := 'BPM';
  FBPM := TEdit.Create(Self);
  FBPM.Parent := Toolbar;
  FBPM.SetBounds(Px(174),Px(8),Px(76),Px(30));
  ApplySyncMusicStudioDarkEdit(FBPM);
  FBPM.OnExit := CommitBPM;
  FBPM.OnKeyDown := BPMKey;

  Center := TPanel.Create(Self);
  Center.Parent := FMain;
  Center.Align := alClient;
  Center.BevelOuter := bvNone;
  ApplySyncMusicStudioDarkPanel(Center);

  FStage := TLipSyncPaintBox.Create(Self);
  FStage.Parent := Center;
  FStage.Align := alTop;
  FStage.Height := Px(232);
  FStage.OnPaint := PaintStage;
  FStage.OnMouseDown := StageMouseDown;
  FStage.OnMouseMove := StageMouseMove;
  FStage.OnMouseUp := StageMouseUp;
  FTimeline := TLipSyncPaintBox.Create(Self);
  FTimeline.Parent := Center;
  FTimeline.Align := alClient;
  FTimeline.OnPaint := PaintTimeline;
  FTimeline.OnMouseDown := TimelineMouseDown;
  FTimeline.OnMouseMove := TimelineMouseMove;
  FTimeline.OnMouseUp := TimelineMouseUp;
  FTempoEditor := TLipSyncTempoEditor.Create(FTimeline,FStatus,CommitTempo);

  FMenu := TPopupMenu.Create(Self);
  FCopyItem := MenuItem('コピー', 11, Ord('C'), [ssCtrl]);
  FPasteItem := MenuItem('再生位置に貼り付け', 12, Ord('V'), [ssCtrl]);
  FDuplicateItem := MenuItem('複製', 14, Ord('D'), [ssCtrl]);
  FDeleteItem := MenuItem('削除', 13, VK_DELETE);
  FDeleteCharacterItem := MenuItem('キャラクターを削除', 15);
  FFlipXItem := MenuItem('左右反転',19);
  FFlipYItem := MenuItem('上下反転',20);
  FFlipXItem.Visible := False;
  FFlipYItem.Visible := False;
  FTempoItem := MenuItem('テンポを追加…',16);
  FUndoItem := MenuItem('元に戻す',17,Ord('Z'),[ssCtrl]);
  FRedoItem := MenuItem('やり直す',18,Ord('Y'),[ssCtrl]);
  FMotionMenu := TPopupMenu.Create(Self);
  for Motion := Low(Motion) to High(Motion) do
  begin
    MotionItem := TMenuItem.Create(FMotionMenu);
    MotionItem.Caption := MusicStudioRhythmCaption(Motion);
    MotionItem.Tag := Ord(Motion);
    MotionItem.RadioItem := True;
    MotionItem.OnClick := MotionPicked;
    FMotionMenu.Items.Add(MotionItem);
  end;

  FPresentationMenu := TPopupMenu.Create(Self);
  Entrance := TMenuItem.Create(FPresentationMenu);
  Entrance.Caption := '登場演出';
  FPresentationMenu.Items.Add(Entrance);
  ExitMenu := TMenuItem.Create(FPresentationMenu);
  ExitMenu.Caption := '退場演出';
  FPresentationMenu.Items.Add(ExitMenu);
  for Cue := Succ(lpNone) to High(Cue) do
  begin
    CueItem := TMenuItem.Create(FPresentationMenu);
    CueItem.Caption := LipSyncPresentationCaption(Cue);
    CueItem.Tag := Ord(Cue);
    CueItem.RadioItem := True;
    CueItem.OnClick := PresentationPicked;
    if LipSyncPresentationIsEntrance(Cue) then Entrance.Add(CueItem)
    else ExitMenu.Add(CueItem);
  end;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 60;
  FTimer.OnTimer := Tick;
end;

procedure TFormLipSyncArrangement.LoadProject(const PSDPath, MusicPath, JSON: string;
  Width, Height: Integer; const ReadBackground: TMusicStudioReadBackground;
  const ApplySettings: TLipSyncApply);
begin
  FProject := TLipSyncProject.Create(PSDPath, MusicPath, JSON);
  RecordEdit;
  FWidth := Max(1, Width);
  FHeight := Max(1, Height);
  FReadBackground := ReadBackground;
  FApply := ApplySettings;
  FBPM.Text := FloatToStr(FProject.Timing.BPMAt(0));
  if FProject.Characters.Count > 0 then FSelected := 0;
  RefreshView;
  Tick(nil);
  FTimer.Enabled := True;
end;

function TFormLipSyncArrangement.IsCharacterRow(Row: Integer): Boolean;
begin
  Result := (Row > 0) and (Row <= FProject.Characters.Count);
end;

function TFormLipSyncArrangement.IsEffectPosition(Row,Y: Integer;
  out Lane: TLipSyncEffectLane): Boolean;
begin
  Lane := elExpression;
  Result := IsCharacterRow(Row) and (Y>=FTimelineView.EffectY(Row,elExpression));
  if Result then
    Lane := TLipSyncEffectLane((Y-FTimelineView.EffectY(Row,elExpression)) div FTimelineView.EffectHeight);
end;

function TFormLipSyncArrangement.EffectHit(Row,X: Integer; Lane: TLipSyncEffectLane;
  out Grip: TLipSyncRangeGrip): TLipSyncEffect;
var
  Effect, EndCandidate: TLipSyncEffect;
  LeftEdge, RightEdge, Margin: Integer;
begin
  Result := nil;
  EndCandidate := nil;
  Grip := rgCreate;
  if (X<FTimelineView.HeaderWidth) or not IsCharacterRow(Row) then Exit;
  for Effect in FProject.Characters[Row-1].Effects do
  begin
    if Effect.Lane<>Lane then Continue;
    LeftEdge := FTimelineView.XAt(Effect.StartBeat);
    RightEdge := FTimelineView.XAt(Effect.EndBeat);
    if (X=RightEdge) and (RightEdge>LeftEdge) then EndCandidate := Effect;
    if (X<LeftEdge) or (X>=RightEdge) then Continue;
    Result := Effect;
    Margin := Min(Max(3,MulDiv(6,CurrentPPI,96)),(RightEdge-LeftEdge) div 3);
    if X<LeftEdge+Margin then Grip := rgStart
    else if X>=RightEdge-Margin then Grip := rgEnd
    else Grip := rgMove;
    Exit;
  end;
  if Assigned(EndCandidate) then
  begin
    Result := EndCandidate;
    Grip := rgEnd;
  end;
end;

procedure TFormLipSyncArrangement.UpdateTimelineCursor(X,Y: Integer);
var
  Row: Integer;
  Lane: TLipSyncEffectLane;
  Grip: TLipSyncRangeGrip;
begin
  Row := FTimelineView.RowAt(Y);
  FTimeline.Cursor := crDefault;
  if FTimelineView.TempoHit(FProject.Timing,X,Y,FTimeline.Width)>=0 then
    FTimeline.Cursor := crHandPoint
  else if IsEffectPosition(Row,Y,Lane) then
  begin
    if not Assigned(EffectHit(Row,X,Lane,Grip)) then Exit;
    if Grip in [rgStart,rgEnd] then FTimeline.Cursor := crSizeWE
    else FTimeline.Cursor := crSizeAll;
  end
  else if Assigned(ClipAt(Row,X)) then
    FTimeline.Cursor := crSizeAll;
end;

procedure TFormLipSyncArrangement.MotionPicked(Sender: TObject);
begin
  if not Assigned(FEffect) or (FEffect.Lane<>elMotion) then Exit;
  FEffect.Motion := TMusicStudioRhythmType(TMenuItem(Sender).Tag);
  RecordEdit;
  RefreshView;
end;

procedure TFormLipSyncArrangement.PresentationPicked(Sender: TObject);
begin
  if not Assigned(FEffect) or (FEffect.Lane<>elPresentation) then Exit;
  FEffect.Presentation := TLipSyncPresentation(TMenuItem(Sender).Tag);
  RecordEdit;
  RefreshView;
end;

function TFormLipSyncArrangement.ClipAt(Row, X: Integer): TLipSyncClip;
var
  Clips: System.Generics.Collections.TObjectList<TLipSyncClip>;
  I: Integer;
begin
  Result := nil;
  if not IsCharacterRow(Row) or (X < FTimelineView.HeaderWidth) then Exit;
  Clips := FProject.Characters[Row - 1].Clips;
  for I := Clips.Count - 1 downto 0 do
    if (X>=FTimelineView.XAt(Clips[I].Beat)) and
      (X<FTimelineView.ClipRight(FProject,Clips[I])) then Exit(Clips[I]);
end;

procedure TFormLipSyncArrangement.RefreshView;
var
  Last: Double;
begin
  Last := Max(32,FProject.ContentEndBeat);
  if Assigned(FProject.Audio) and FProject.Audio.Done then
    Last := Max(Last, FProject.Timing.SecondsToBeat(FProject.Audio.Info.Duration));
  FLastBeat := Last;
  FTimelineView.StartBeat := EnsureRange(FTimelineView.StartBeat, 0.0, FLastBeat + 16);
  FTimelineView.TopRow := EnsureRange(FTimelineView.TopRow, 0, MaxTopRow);
  FTimeline.Invalidate;
  FStage.Invalidate;
end;

function TFormLipSyncArrangement.MaxTopRow: Integer;
begin
  Result := Max(0, FProject.Characters.Count -
    Max(1, (FTimeline.Height - FTimelineView.RulerHeight - FTimelineView.RowHeight) div FTimelineView.CharacterHeight));
end;

procedure TFormLipSyncArrangement.Wheel(Sender: TObject; Shift: TShiftState;
  Delta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  P: TPoint;
  Beat, Steps: Double;
  Row: Integer;
begin
  if Handled or not FMain.Visible or (FProject = nil) or (Delta = 0) then Exit;
  P := FStage.ScreenToClient(MousePos);
  if FStage.ClientRect.Contains(P) then
  begin
    if not FStagePanning and (FStageGrip = 0) then
      FStageView.ZoomAt(MusicStudioFitFrameRect(FStage.ClientRect,FWidth,FHeight),P,Delta);
    FStage.Invalidate;
    Handled := True;
    Exit;
  end;
  P := FTimeline.ScreenToClient(MousePos);
  if not FTimeline.ClientRect.Contains(P) then Exit;
  Handled := True;
  if FClipPressed or FEffectPressed or not FTempoEditor.Finish then Exit;
  Steps := Delta / 120;
  if P.X < FTimelineView.HeaderWidth then
  begin
    if P.Y < FTimelineView.RulerHeight then Exit;
    if ssCtrl in Shift then
    begin
      Row := FTimelineView.RowAt(P.Y);
      FTimelineView.RowHeight := EnsureRange(Round(FTimelineView.RowHeight * Power(1.15, Steps)),
        FTimelineView.Px(MIN_ROW_HEIGHT),FTimelineView.Px(MAX_ROW_HEIGHT));
      if Row > 0 then FTimelineView.TopRow := Row-1-Max(0,P.Y-FTimelineView.RulerHeight-FTimelineView.RowHeight) div FTimelineView.CharacterHeight;
    end
    else
      FTimelineView.TopRow := FTimelineView.TopRow - Sign(Delta) * Max(1, Round(Abs(Steps)));
    FTimelineView.TopRow := EnsureRange(FTimelineView.TopRow, 0, MaxTopRow);
  end
  else if (P.Y < FTimelineView.RulerHeight) or (ssCtrl in Shift) then
  begin
    Beat := FTimelineView.BeatAt(P.X);
    FTimelineView.PixelsPerBeat := EnsureRange(FTimelineView.PixelsPerBeat*Power(1.2,Steps),FTimelineView.Px(6),FTimelineView.Px(320));
    FTimelineView.StartBeat := Beat - (P.X - FTimelineView.HeaderWidth) / FTimelineView.PixelsPerBeat;
  end
  else
    FTimelineView.StartBeat := FTimelineView.StartBeat - Steps*FTimelineView.Px(120)/FTimelineView.PixelsPerBeat;
  FTimelineView.StartBeat := EnsureRange(FTimelineView.StartBeat, 0.0, FLastBeat + 16);
  FTimeline.Invalidate;
end;

procedure TFormLipSyncArrangement.StageMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if not (Button in [mbLeft, mbMiddle]) then Exit;
  if Button = mbLeft then
    FStageGrip := LipSyncGripAt(FSelectedBounds,Point(X,Y),Max(3,MulDiv(5,CurrentPPI,96)));
  if FStageGrip <> 0 then
  begin
    FStageMouse := Point(X,Y);
    FEditStartBounds := FSelectedBounds;
    FEditStartFrame := FStageFrame;
    FStageOriginal := FProject.Characters[FSelected].Scene.TransformFor(FWidth,FHeight);
    FStageDraft := FStageOriginal;
    SetCaptureControl(FStage);
    Exit;
  end;
  if ssDouble in Shift then
  begin
    FStageView.Reset;
    FStage.Invalidate;
    Exit;
  end;
  FStageMouse := Point(X,Y);
  FStagePanning := True;
  FStage.Cursor := crSizeAll;
  SetCaptureControl(FStage);
end;

procedure TFormLipSyncArrangement.StageMouseMove(Sender: TObject;
  Shift: TShiftState; X, Y: Integer);
begin
  if not FStagePanning and (FStageGrip = 0) then
  begin
    case LipSyncGripAt(FSelectedBounds,Point(X,Y),Max(3,MulDiv(5,CurrentPPI,96))) of
      1,4: FStage.Cursor := crSizeNWSE;
      2,3: FStage.Cursor := crSizeNESW;
      5: FStage.Cursor := crSizeAll;
    else
      FStage.Cursor := crDefault;
    end;
    Exit;
  end;
  if GetCaptureControl <> FStage then
  begin
    FStageGrip := 0;
    FStagePanning := False;
    FStage.Cursor := crDefault;
    FStage.Invalidate;
    Exit;
  end;
  if FStageGrip <> 0 then
    FStageDraft := LipSyncDragPlacement(FStageOriginal,FEditStartBounds,FEditStartFrame,
      FWidth,FHeight,FStageGrip,X-FStageMouse.X,Y-FStageMouse.Y)
  else
  begin
    FStageView.PanBy(X-FStageMouse.X,Y-FStageMouse.Y);
    FStageMouse := Point(X,Y);
  end;
  FStage.Invalidate;
end;

procedure TFormLipSyncArrangement.StageMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if not (Button in [mbLeft,mbMiddle]) then Exit;
  if (FStageGrip <> 0) and (Button = mbLeft) then
  begin
    FStageDraft := LipSyncDragPlacement(FStageOriginal,FEditStartBounds,FEditStartFrame,
      FWidth,FHeight,FStageGrip,X-FStageMouse.X,Y-FStageMouse.Y);
    FStageGrip := 0;
    if (X <> FStageMouse.X) or (Y <> FStageMouse.Y) then
    begin
      FProject.Characters[FSelected].UpdatePlacement(FStageDraft);
      RecordEdit;
    end;
  end
  else if FStagePanning then
    FStageView.PanBy(X-FStageMouse.X,Y-FStageMouse.Y)
  else Exit;
  FStagePanning := False;
  FStage.Cursor := crDefault;
  SetCaptureControl(nil);
  FStage.Invalidate;
end;
procedure TFormLipSyncArrangement.PaintTimeline(Sender: TObject);
var
  State: TLipSyncTimelinePaintState;
begin
  if (FProject = nil) or (FTimeline.Width <= 0) or (FTimeline.Height <= 0) then Exit;
  FTimelineBuffer.SetSize(FTimeline.Width,FTimeline.Height);
  State.Selected := FSelected;
  State.SelectedTempo := FSelectedTempo;
  State.Clip := FClip;
  State.Effect := FEffect;
  State.CursorSeconds := FCursor;
  State.ClipDragging := FDragging;
  State.DragRow := FDragRow;
  State.DragBeat := FDragBeat;
  // ドラッグ中は保存データを更新せず、候補範囲を裏バッファへ描く。
  State.EffectDragging := FEffectPressed and FEffectChanged;
  State.EffectCreating := FEffectGrip = rgCreate;
  State.EffectRow := FEffectRow;
  State.EffectLane := FEffectLane;
  State.EffectFrom := FEffectFrom;
  State.EffectTo := FEffectTo;
  PaintLipSyncTimeline(FTimelineBuffer.Canvas,FTimeline.Width,FTimeline.Height,Font,
    FProject,FTimelineView,State);
  FTimeline.Canvas.Draw(0,0,FTimelineBuffer);
end;


procedure TFormLipSyncArrangement.PaintStage(Sender: TObject);
var
  C: TCanvas;
  Frame, Bounds: TRect;
  Character: TLipSyncCharacter;
  Blend: TBlendFunction;
  I, Save: Integer;
  Presentation: TLipSyncPresentationFrame;
begin
  if (FProject = nil) or (FStage.Width <= 0) or (FStage.Height <= 0) then Exit;
  FStageBuffer.SetSize(FStage.Width,FStage.Height);
  C := FStageBuffer.Canvas;
  C.Brush.Color := $00202020;
  C.FillRect(FStage.ClientRect);
  Frame := FStageView.Frame(MusicStudioFitFrameRect(FStage.ClientRect,FWidth,FHeight));
  FStageFrame := Frame;
  FSelectedBounds := TRect.Empty;
  C.Brush.Color := clBlack;
  C.FillRect(Frame);
  if not FBackground.Empty then C.StretchDraw(Frame,FBackground);
  Blend.BlendOp := AC_SRC_OVER;
  Blend.BlendFlags := 0;
  Blend.AlphaFormat := AC_SRC_ALPHA;
  Save := SaveDC(C.Handle);
  try
    IntersectClipRect(C.Handle,Frame.Left,Frame.Top,Frame.Right,Frame.Bottom);
    for I := FProject.Characters.Count - 1 downto 0 do
    begin
      Character := FProject.Characters[I];
      if Character.PsdMissing then Continue;
      if (I = FSelected) and (FStageGrip <> 0) then
        Bounds := Character.Scene.Placement(Frame,FWidth,FHeight,FStageDraft)
      else
        Bounds := Character.Scene.Placement(Frame,FWidth,FHeight);
      if I = FSelected then FSelectedBounds := Bounds;
      Presentation := Character.PresentationAt(FProject.Timing,FCursor);
      if (Presentation.Opacity = 0) or
        not Character.Render(FImage,FProject.Timing,FProject.Audio,FCursor) then Continue;
      Bounds := Presentation.AdjustBounds(Frame,Bounds);
      Blend.SourceConstantAlpha := Presentation.Opacity;
      Winapi.Windows.AlphaBlend(C.Handle,Bounds.Left,Bounds.Top,Bounds.Width,Bounds.Height,
        FImage.Canvas.Handle,0,0,FImage.Width,FImage.Height,Blend);
    end;
  finally
    RestoreDC(C.Handle,Save);
  end;
  DrawLipSyncPlacement(C,FSelectedBounds,Max(3,MulDiv(5,CurrentPPI,96)));
  FStage.Canvas.Draw(0,0,FStageBuffer);
end;

procedure TFormLipSyncArrangement.Tick(Sender: TObject);
var
  Background: TMusicStudioBackgroundSnapshot;
  Playback: TMusicStudioPlaybackSnapshot;
  X,Y: Integer;
  Row: PByte;
  State: string;
begin
  if FProject = nil then Exit;
  if GetTickCount64-FMissingCheckTick>=1000 then
  begin
    FMissingCheckTick := GetTickCount64;
    if FProject.CheckMissingAssets then RefreshView;
    if FProject.AudioMissing and Assigned(FPlayback) then StopPlayback(False);
  end;
  if Assigned(FReadBackground) and FReadBackground(FSerial,Background) and
    (Length(Background.Pixels)>0) then
  begin
    FSerial := Background.Serial;
    FBackground.PixelFormat := pf32bit;
    FBackground.SetSize(Background.Width,Background.Height);
    for Y := 0 to Background.Height-1 do
    begin
      Row := FBackground.ScanLine[Y];
      for X := 0 to Background.Width-1 do
        with Background.Pixels[Y*Background.Width+X] do
        begin
          Row[X*4] := B; Row[X*4+1] := G; Row[X*4+2] := R; Row[X*4+3] := 0;
        end;
    end;
    FStage.Invalidate;
  end;
  if Assigned(FPlayback) then
  begin
    Playback := FPlayback.Snapshot;
    FCursor := Playback.Position;
    FTimeline.Invalidate;
    FStage.Invalidate;
    if Playback.State in [psFailed,psFinished] then
    begin
      if Playback.State = psFailed then FStatus.Caption := Playback.Message;
      StopPlayback(False);
    end;
  end;
  if FSilentPlaying then
  begin
    FCursor := SilentPosition;
    if FCursor >= FSilentEnd then StopPlayback(False);
    FTimeline.Invalidate;
    FStage.Invalidate;
  end;
  if Assigned(FProject.Audio) and FProject.Audio.Done and not FAudioReady then
  begin
    FAudioReady := True;
    State := FProject.Audio.ErrorText;
    if State <> '' then FStatus.Caption := State;
    RefreshView;
  end;
end;

procedure TFormLipSyncArrangement.TimelineMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X,Y: Integer);
var
  Row: Integer;
  P: TPoint;
  Lane: TLipSyncEffectLane;
  Grip: TLipSyncRangeGrip;
  OnEffectLane: Boolean;
  Transform: TMusicStudioPsdTransform;
  Branch, Item: TMenuItem;
begin
  if not (Button in [mbLeft,mbRight]) or not FTempoEditor.Finish then Exit;
  ActiveControl := nil;
  FSelectedTempo := FTimelineView.TempoHit(FProject.Timing,X,Y,FTimeline.Width);
  if FSelectedTempo>=0 then FTempoBeat := FProject.Timing.TempoPoint(FSelectedTempo).Beat
  else FTempoBeat := FTimelineView.SnapBeat(FProject.Timing,FTimelineView.BeatAt(X));
  Row := FTimelineView.RowAt(Y);
  if Row >= 0 then
  begin
    if IsCharacterRow(Row) then FSelected := Row-1 else FSelected := -1;
    FSelectedBounds := TRect.Empty;
  end;
  FEffect := nil;
  OnEffectLane := IsEffectPosition(Row,Y,Lane);
  FCharacterHeaderSelected := IsCharacterRow(Row) and not OnEffectLane and (X<FTimelineView.HeaderWidth);
  if OnEffectLane then
  begin
    FClip := nil;
    FEffect := EffectHit(Row,X,Lane,Grip);
  end
  else
    FClip := ClipAt(Row,X);
  if Assigned(FClip) and FClip.Missing then FStatus.Caption := '欠損: '+FClip.Path
  else if (Row=0) and FProject.AudioMissing then FStatus.Caption := '欠損: '+FProject.AudioPath
  else if IsCharacterRow(Row) and FProject.Characters[Row-1].PsdMissing then
    FStatus.Caption := '欠損: '+FProject.Characters[Row-1].PSDPath
  else if FCharacterHeaderSelected then FStatus.Caption := FProject.Characters[Row-1].PSDPath;
  if (Button=mbLeft) and (ssDouble in Shift) and FCharacterHeaderSelected then
  begin
    OpenPSD;
    Exit;
  end;
  if Button = mbRight then
  begin
    if X >= FTimelineView.HeaderWidth then FCursor := FProject.Timing.BeatToSeconds(FTimelineView.BeatAt(X));
    RefreshView;
    FCopyItem.Enabled := Assigned(FClip);
    FDuplicateItem.Enabled := Assigned(FClip);
    FDeleteItem.Enabled := FCharacterHeaderSelected or (FSelectedTempo>0) or Assigned(FClip) or Assigned(FEffect);
    if FCharacterHeaderSelected then FDeleteItem.Caption := 'トラックを削除'
    else FDeleteItem.Caption := '削除';
    FTempoItem.Enabled := X>=FTimelineView.HeaderWidth;
    if FSelectedTempo>=0 then FTempoItem.Caption := 'テンポを編集…'
    else FTempoItem.Caption := 'テンポを追加…';
    FUndoItem.Enabled := FHistory.CanStep(-1);
    FRedoItem.Enabled := FHistory.CanStep(1);
    FPasteItem.Enabled := IsCharacterRow(Row) and Assigned(FClipboard);
    FDeleteCharacterItem.Visible := IsCharacterRow(Row) and not FCharacterHeaderSelected;
    FFlipXItem.Visible := FCharacterHeaderSelected;
    FFlipYItem.Visible := FFlipXItem.Visible;
    if FFlipXItem.Visible then
    begin
      Transform := FProject.Characters[FSelected].Scene.TransformFor(FWidth,FHeight);
      FFlipXItem.Checked := Transform.FlipX;
      FFlipYItem.Checked := Transform.FlipY;
    end;
    P := FTimeline.ClientToScreen(Point(X,Y));
    FMenu.Popup(P.X,P.Y);
    Exit;
  end;
  StopPlayback(False);
  if X >= FTimelineView.HeaderWidth then FCursor := FProject.Timing.BeatToSeconds(FTimelineView.BeatAt(X));
  if (FSelectedTempo>=0) and (ssDouble in Shift) then
  begin
    FTempoEditor.Open(FTimelineView.XAt(FTempoBeat),FTempoBeat,FProject.Timing.BPMAt(FTempoBeat),FTimelineView);
    RefreshView;
    Exit;
  end;
  if OnEffectLane and (X>=FTimelineView.HeaderWidth) then
  begin
    if (ssDouble in Shift) and Assigned(FEffect) then
    begin
      if Lane = elExpression then
      begin
        EditLipSyncExpression(FProject.Characters[Row-1],FEffect);
        RecordEdit;
      end
      else if Lane = elMotion then
      begin
        for Item in FMotionMenu.Items do
          Item.Checked := Item.Tag = Ord(FEffect.Motion);
        P := FTimeline.ClientToScreen(Point(X,Y));
        FMotionMenu.Popup(P.X,P.Y);
      end
      else
      begin
        for Branch in FPresentationMenu.Items do
          for Item in Branch do Item.Checked := Item.Tag = Ord(FEffect.Presentation);
        P := FTimeline.ClientToScreen(Point(X,Y));
        FPresentationMenu.Popup(P.X,P.Y);
      end;
    end
    else
    begin
      FEffectPressed := True;
      FEffectChanged := False;
      FEffectLane := Lane;
      FEffectRow := Row;
      FEffectDownX := X;
      FEffectGrip := Grip;
      FEffectAnchor := FTimelineView.BeatAt(X);
      if (Grip=rgCreate) and not (ssAlt in Shift) then
        FEffectAnchor := FTimelineView.SnapBeat(FProject.Timing,FEffectAnchor);
      SetCaptureControl(FTimeline);
      UpdateTimelineCursor(X,Y);
    end;
    RefreshView;
    Exit;
  end;
  if FClip <> nil then
  begin
    FClipPressed := True;
    FDownX := X;
    FDragRow := Row;
    FDragBeat := FClip.Beat;
    FDragOffset := FTimelineView.BeatAt(X)-FClip.Beat;
    SetCaptureControl(FTimeline);
  end;
  RefreshView;
end;

procedure TFormLipSyncArrangement.TimelineMouseMove(Sender: TObject; Shift: TShiftState; X,Y: Integer);
begin
  if FEffectPressed then
  begin
    if not (ssLeft in Shift) then Exit;
    if GetCaptureControl <> FTimeline then
    begin
      FEffectPressed := False;
      UpdateTimelineCursor(X,Y);
    end
    else
      UpdateEffectDrag(Shift,X);
    FTimeline.Invalidate;
    Exit;
  end;
  if not FClipPressed then
  begin
    UpdateTimelineCursor(X,Y);
    Exit;
  end;
  if (FClip = nil) or not (ssLeft in Shift) then Exit;
  if GetCaptureControl <> FTimeline then
  begin
    FClipPressed := False;
    FDragging := False;
    FTimeline.Cursor := crDefault;
    FTimeline.Invalidate;
    Exit;
  end;
  UpdateClipDrag(Shift,X,Y);
end;

procedure TFormLipSyncArrangement.UpdateEffectDrag(Shift: TShiftState; X: Integer);
var
  Position, Delta, Step, Duration, Minimum: Double;
  function Snap(Beat: Double): Double;
  begin
    if ssAlt in Shift then Result := Beat
    else Result := FTimelineView.SnapBeat(FProject.Timing,Beat);
  end;
begin
  FEffectChanged := Abs(X-FEffectDownX)>=FTimelineView.Px(4);
  if not FEffectChanged then Exit;
  Step := FTimelineView.GridStep(FProject.Timing,FEffectAnchor);
  Position := FTimelineView.BeatAt(X);
  if FEffectGrip=rgCreate then
  begin
    Position := Snap(Position);
    FEffectFrom := Min(FEffectAnchor,Position);
    FEffectTo := Max(FEffectAnchor,Position);
    FEffectChanged := FEffectFrom<FEffectTo;
    Exit;
  end;
  FEffectFrom := FEffect.StartBeat;
  FEffectTo := FEffect.EndBeat;
  Duration := FEffectTo-FEffectFrom;
  Minimum := Min(Duration,Step);
  if ssAlt in Shift then Minimum := Min(Duration,1/64);
  Delta := Position-FEffectAnchor;
  case FEffectGrip of
    rgMove:
      begin
        FEffectFrom := EnsureRange(Snap(FEffectFrom+Delta),0.0,1000000-Duration);
        FEffectTo := FEffectFrom+Duration;
      end;
    rgStart: FEffectFrom := EnsureRange(Snap(FEffectFrom+Delta),0.0,FEffectTo-Minimum);
    rgEnd: FEffectTo := EnsureRange(Snap(FEffectTo+Delta),FEffectFrom+Minimum,1000000.0);
  end;
  FEffectChanged := (FEffectFrom<>FEffect.StartBeat) or (FEffectTo<>FEffect.EndBeat);
end;

procedure TFormLipSyncArrangement.UpdateClipDrag(Shift: TShiftState; X,Y: Integer);
var
  Row: Integer;
  Lane: TLipSyncEffectLane;
begin
  Row := FTimelineView.RowAt(Y);
  if not FDragging and (Abs(X-FDownX)<FTimelineView.Px(4)) and (Row=FSelected+1) then Exit;
  FDragging := True;
  if IsCharacterRow(Row) and not IsEffectPosition(Row,Y,Lane) and
    (X >= FTimelineView.HeaderWidth) and FTimeline.ClientRect.Contains(Point(X,Y)) then
  begin
    FDragRow := Row;
    FTimeline.Cursor := crSizeAll;
    FDragBeat := EnsureRange(FTimelineView.BeatAt(X)-FDragOffset,0.0,1000000.0);
    if not (ssAlt in Shift) then
      FDragBeat := FTimelineView.SnapBeat(FProject.Timing,FDragBeat);
  end
  else
  begin
    FDragRow := -1;
    FTimeline.Cursor := crNoDrop;
  end;
  FTimeline.Invalidate;
end;

procedure TFormLipSyncArrangement.TimelineMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X,Y: Integer);
var
  Old: TLipSyncCharacter;
begin
  if Button <> mbLeft then Exit;
  if FEffectPressed then
  begin
    FEffectPressed := False;
    SetCaptureControl(nil);
    UpdateEffectDrag(Shift,X);
    if FEffectChanged then
      try
        Old := FProject.Characters[FEffectRow-1];
        if FEffectGrip=rgCreate then
        begin
          FEffect := Old.AddEffect(FEffectLane,FEffectFrom,FEffectTo);
          FStatus.Caption := '区間をダブルクリックして設定';
        end
        else
          Old.SetEffectRange(FEffect,FEffectFrom,FEffectTo);
        RecordEdit;
      except on E: Exception do FStatus.Caption := E.Message; end;
    UpdateTimelineCursor(X,Y);
    RefreshView;
    Exit;
  end;
  // VCL は OnMouseUp を呼ぶ前にキャプチャを解除する。
  if FClipPressed and Assigned(FClip) then UpdateClipDrag(Shift,X,Y);
  FClipPressed := False;
  SetCaptureControl(nil);
  if FDragging and IsCharacterRow(FDragRow) and Assigned(FClip) then
  begin
    Old := FProject.Characters[FSelected];
    if FDragRow-1 <> FSelected then
    begin
      FProject.Characters[FDragRow-1].Clips.Add(Old.Clips.Extract(FClip));
      FSelected := FDragRow-1;
    end;
    FClip.Beat := FDragBeat;
    RecordEdit;
  end;
  FDragging := False;
  UpdateTimelineCursor(X,Y);
  RefreshView;
end;
procedure TFormLipSyncArrangement.AddMedia(const Path: string; Row: Integer; Beat: Double;
  Target: TLipSyncClip);
var
  Character: TLipSyncCharacter;
  Relinking: Boolean;
begin
  Relinking := False;
  if not FileExists(Path) then raise EArgumentException.Create('ファイルが見つかりません。');
  FSelectedTempo := -1;
  FCharacterHeaderSelected := False;
  if SameText(ExtractFileExt(Path),'.psd') then
  begin
    if IsCharacterRow(Row) and FProject.Characters[Row-1].PsdMissing then
    begin
      FProject.Characters[Row-1].ReplacePSD(Path);
      Relinking := True;
      FSelected := Row-1;
    end
    else
    begin
      Character := TLipSyncCharacter.Create(Path,'{}');
      if not Character.Scene.Document.Loaded then
      begin
        try
          raise EArgumentException.Create(Character.Scene.Document.LastError);
        finally
          Character.Free;
        end;
      end;
      FSelected := FProject.Characters.Add(Character);
    end;
    FClip := nil;
    FEffect := nil;
    RefreshView;
    if FTimelineView.RowY(FSelected+1) + FTimelineView.CharacterHeight > FTimeline.Height then
      FTimelineView.TopRow := MaxTopRow;
  end
  else
    case LipSyncMode(Path) of
      lmEnvelope:
        begin
          Relinking := FProject.AudioMissing;
          StopPlayback(not Relinking);
          FProject.SetAudio(Path);
          FAudioReady := False;
        end;
      lmPhonemes:
        begin
          if (Row < 1) or (Row > FProject.Characters.Count) then
            raise EArgumentException.Create('歌唱データはキャラクターのタイムラインへ置いてください。');
          FSelected := Row-1;
          FEffect := nil;
          if Assigned(Target) and Target.Missing then
          begin
            Target.ReplaceSource(Path);
            Relinking := True;
            FClip := Target;
          end
          else
          begin
            FClip := TLipSyncClip.Create(Path,Beat,True);
            FProject.Characters[FSelected].Clips.Add(FClip);
          end;
        end;
    else
      raise EArgumentException.Create('このファイル形式には対応していません。');
    end;
  if Relinking then FProject.MarkRelink;
  FStatus.Caption := ExtractFileName(Path);
  RefreshView;
end;

procedure TFormLipSyncArrangement.DropFiles(var Msg: TMessage);
var
  Drop: HDROP;
  P: TPoint;
  I, Count, Size: Cardinal;
  Row, MediaRow: Integer;
  CanDropSinging: Boolean;
  Path: string;
  Beat: Double;
  Lane: TLipSyncEffectLane;
  Target: TLipSyncClip;
begin
  Drop := HDROP(Msg.WParam);
  try
    if not FMain.Visible or not FTempoEditor.Finish then Exit;
    DragQueryPoint(Drop,P);
    P := FTimeline.ScreenToClient(ClientToScreen(P));
    if FProject.CheckMissingAssets then RefreshView;
    Row := FTimelineView.RowAt(P.Y);
    Target := nil;
    CanDropSinging := not IsEffectPosition(Row,P.Y,Lane);
    if CanDropSinging then Target := ClipAt(Row,P.X);
    Beat := FTimelineView.SnapBeat(FProject.Timing,FTimelineView.BeatAt(P.X));
    Count := DragQueryFile(Drop,$FFFFFFFF,nil,0);
    I := 0;
    while I < Count do
    begin
      Size := DragQueryFile(Drop,I,nil,0);
      SetLength(Path,Size);
      DragQueryFile(Drop,I,PChar(Path),Size+1);
      try
        MediaRow := Row;
        if (LipSyncMode(Path)=lmPhonemes) and not CanDropSinging then MediaRow := -1;
        AddMedia(Path,MediaRow,Beat,Target);
        if SameText(ExtractFileExt(Path),'.psd') then
        begin
          if Row<>FSelected+1 then Target := nil;
          Row := FSelected+1;
          CanDropSinging := True;
        end;
      except on E: Exception do FStatus.Caption := E.Message; end;
      Inc(I);
    end;
    RecordEdit;
  finally
    DragFinish(Drop);
  end;
end;

procedure TFormLipSyncArrangement.UpdatePlaybackButton;
begin
  if Assigned(FPlayback) or FSilentPlaying then
  begin
    FPlayButton.Caption := '⏸';
    FPlayButton.Hint := '一時停止 (Space)';
  end
  else
  begin
    FPlayButton.Caption := '▶';
    FPlayButton.Hint := '再生 / 再開 (Space)';
  end;
end;

function TFormLipSyncArrangement.SilentPosition: Double;
begin
  // タイマーの呼出間隔に依存せず、単調増加時計で試写位置を求める。
  Result := Min(FSilentEnd,FSilentStart+(GetTickCount64-FSilentTick)/1000.0);
end;

procedure TFormLipSyncArrangement.StopPlayback(ResetCursor: Boolean);
begin
  if ResetCursor then FCursor := 0
  else if Assigned(FPlayback) then FCursor := FPlayback.Snapshot.Position
  else if FSilentPlaying then FCursor := SilentPosition;
  FSilentPlaying := False;
  FreeAndNil(FPlayback);
  UpdatePlaybackButton;
end;

procedure TFormLipSyncArrangement.TogglePlayback;
var
  Clips: TMusicStudioPreviewClips;
  LastBeat: Double;
begin
  if Assigned(FPlayback) or FSilentPlaying then
  begin
    StopPlayback(False);
    Exit;
  end;
  if not Assigned(FProject.Audio) then
  begin
    LastBeat := FProject.ContentEndBeat;
    if LastBeat = 0 then LastBeat := FProject.Timing.MeasureStart(2);
    FSilentEnd := FProject.Timing.BeatToSeconds(LastBeat);
    if FCursor >= FSilentEnd then FCursor := 0;
    FSilentStart := FCursor;
    FSilentTick := GetTickCount64;
    FSilentPlaying := True;
    UpdatePlaybackButton;
    Exit;
  end;
  if not FProject.Audio.Done then
    raise EArgumentException.Create('基準音源の解析完了を待ってください。');
  if FProject.Audio.ErrorText <> '' then
    raise EArgumentException.Create(FProject.Audio.ErrorText);
  if FProject.Audio.Info.Duration <= 0 then Exit;
  if FCursor >= FProject.Audio.Info.Duration then FCursor := 0;
  SetLength(Clips,1);
  Clips[0].FilePath := FProject.AudioPath;
  Clips[0].LengthSeconds := FProject.Audio.Info.Duration;
  Clips[0].Volume := 1;
  FPlayback := TMusicStudioPlaybackJob.Create(Clips,FCursor,Clips[0].LengthSeconds);
  FPlayback.Start;
  UpdatePlaybackButton;
end;

procedure TFormLipSyncArrangement.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if not FMain.Visible then
  begin
    if Key = VK_ESCAPE then
    begin
      ClosePSD;
      Key := 0;
    end;
    Exit;
  end;
  if Key = VK_SPACE then
  begin
    if not FSpaceHeld then
    begin
      FSpaceHeld := True;
      Command(FPlayButton);
    end;
    Key := 0;
    Exit;
  end;
  if ActiveControl is TCustomEdit then Exit;
  if (Key=VK_ESCAPE) and (FDragging or FEffectPressed) then
  begin
    SetCaptureControl(nil);
    FClipPressed := False;
    FEffectPressed := False;
    FDragging := False;
    FTimeline.Cursor := crDefault;
    FTimeline.Invalidate;
    Key := 0;
  end
  else if not FClipPressed and not FEffectPressed then
  begin
    if (Key=VK_DELETE) and (Shift=[]) and (FStageGrip=0) and not FStagePanning then
    begin
      Command(FDeleteItem);
      Key := 0;
    end
    else if (Shift=[ssCtrl]) and (Key=Ord('C')) then begin Command(FCopyItem); Key := 0; end
    else if (Shift=[ssCtrl]) and (Key=Ord('V')) then begin Command(FPasteItem); Key := 0; end
    else if (Shift=[ssCtrl]) and (Key=Ord('D')) then begin Command(FDuplicateItem); Key := 0; end
    else if (Shift=[ssCtrl]) and (Key=Ord('Z')) then begin Command(FUndoItem); Key := 0; end
    else if ((Shift=[ssCtrl]) and (Key=Ord('Y'))) or
      ((Shift=[ssCtrl,ssShift]) and (Key=Ord('Z'))) then begin Command(FRedoItem); Key := 0; end;
  end;
end;

procedure TFormLipSyncArrangement.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_SPACE then FSpaceHeld := False;
end;

procedure TFormLipSyncArrangement.FormDeactivate(Sender: TObject);
begin
  FSpaceHeld := False;
end;

procedure TFormLipSyncArrangement.Command(Sender: TObject);
var
  Tag: Integer;
  Character: TLipSyncCharacter;
  Transform: TMusicStudioPsdTransform;
  Beat: Double;
begin
  try
    Tag := TComponent(Sender).Tag;
    if (Tag=13) and FCharacterHeaderSelected then Tag := 15;
    case Tag of
      3: TogglePlayback;
      4: StopPlayback(True);
      9: Close;
      11:
        if Assigned(FClip) then
        begin
          FreeAndNil(FClipboard);
          FClipboard := FClip.Duplicate(FClip.Beat);
        end;
      12:
        if Assigned(FClipboard) and (FSelected>=0) then
        begin
          FCharacterHeaderSelected := False;
          FEffect := nil;
          FClip := FClipboard.Duplicate(FTimelineView.SnapBeat(FProject.Timing,
            FProject.Timing.SecondsToBeat(FCursor)));
          FProject.Characters[FSelected].Clips.Add(FClip);
        end;
      13:
        if FSelectedTempo>0 then
        begin
          FProject.Timing.DeleteTempoPoint(FSelectedTempo);
          FSelectedTempo := -1;
        end
        else if FSelected>=0 then
        begin
          if Assigned(FClip) then
          begin
            FProject.Characters[FSelected].Clips.Remove(FClip);
            FClip := nil;
          end
          else if Assigned(FEffect) then
          begin
            FProject.Characters[FSelected].Effects.Remove(FEffect);
            FEffect := nil;
          end;
        end;
      14:
        if Assigned(FClip) and (FSelected>=0) then
        begin
          Beat := FProject.EndBeat(FClip);
          if Beat > 1000000 then raise EArgumentException.Create('複製先がタイムラインの上限を超えます。');
          FClip := FClip.Duplicate(Beat);
          FProject.Characters[FSelected].Clips.Add(FClip);
          FCursor := FProject.Timing.BeatToSeconds(Beat);
          if (FTimelineView.XAt(Beat) < FTimelineView.HeaderWidth) or (FTimelineView.XAt(Beat) >= FTimeline.Width) then
            FTimelineView.StartBeat := Max(0.0, Beat - FTimelineView.Px(24) / FTimelineView.PixelsPerBeat);
        end;
      15:
        if FSelected>=0 then
        begin
          Character := FProject.Characters[FSelected];
          if MessageDlg(ExtractFileName(Character.PSDPath)+' をトラックごと削除しますか？',
            mtConfirmation,[mbYes,mbNo],0)=mrYes then
          begin
            FClip := nil;
            FEffect := nil;
            FCharacterHeaderSelected := False;
            FSelectedBounds := TRect.Empty;
            FProject.Characters.Delete(FSelected);
            FSelected := Min(FSelected,FProject.Characters.Count-1);
            FStatus.Caption := '';
          end;
        end;
      16: FTempoEditor.Open(FTimelineView.XAt(FTempoBeat),FTempoBeat,
        FProject.Timing.BPMAt(FTempoBeat),FTimelineView);
      17: RestoreEdit(-1);
      18: RestoreEdit(1);
      19,20:
        if FSelected>=0 then
        begin
          Character := FProject.Characters[FSelected];
          Transform := Character.Scene.TransformFor(FWidth,FHeight);
          if Tag=19 then Transform.FlipX := not Transform.FlipX
          else Transform.FlipY := not Transform.FlipY;
          Character.UpdatePlacement(Transform);
          FreeAndNil(Character.Thumbnail);
          RecordEdit;
        end;
    end;
    if Tag in [12..15] then RecordEdit;
    if ModalResult=mrNone then RefreshView;
  except on E: Exception do FStatus.Caption := E.Message; end;
end;

procedure TFormLipSyncArrangement.SetEditorVisible(Value: Boolean);
begin
  FMain.Visible := not Value;
  FEditorPanel.Visible := Value;
  if Value then FCloseButton.Caption := '閉じて統合編集へ'
  else FCloseButton.Caption := '閉じる';
  if Value then Caption := '口パク - PSD編集'
  else Caption := '口パク - 統合編集';
end;

procedure TFormLipSyncArrangement.ClosePSD;
begin
  if not Assigned(FPsdEditor) or not FPsdEditor.CommitSettings then Exit;
  FreeAndNil(FPsdEditor);
  SetEditorVisible(False);
  RefreshView;
end;

procedure TFormLipSyncArrangement.CloseForm(Sender: TObject; var CanClose: Boolean);
begin
  if Assigned(FPsdEditor) then
  begin
    CanClose := False;
    ClosePSD;
    ModalResult := mrNone;
    Exit;
  end;
  if FProject = nil then Exit;
  try
    CanClose := FTempoEditor.Finish;
    if CanClose then SaveProject;
  except
    on E: Exception do
    begin
      CanClose := False;
      ModalResult := mrNone;
      FStatus.Caption := E.Message;
    end;
  end;
end;

procedure TFormLipSyncArrangement.CommitBPM(Sender: TObject);
var
  BPM: Double;
begin
  if FProject = nil then Exit;
  if not TryStrToFloat(FBPM.Text,BPM) or IsNan(BPM) or IsInfinite(BPM) or
    (BPM<1) or (BPM>999.99) then
  begin
    FBPM.Text := FloatToStr(FProject.Timing.BPMAt(0));
    FStatus.Caption := 'BPM は 1～999.99 の範囲で入力してください。';
    Exit;
  end;
  if BPM = FProject.Timing.BPMAt(0) then Exit;
  FProject.Timing.SetBPMAt(0,BPM);
  RecordEdit;
  RefreshView;
end;

procedure TFormLipSyncArrangement.CommitTempo(Beat,BPM: Double);
begin
  FProject.Timing.SetBPMAt(Beat,BPM);
  FClip := nil;
  FEffect := nil;
  FCharacterHeaderSelected := False;
  FSelectedTempo := FProject.Timing.TempoPointIndexAtBeat(Beat);
  FBPM.Text := FloatToStr(FProject.Timing.BPMAt(0));
  RecordEdit;
  RefreshView;
end;

procedure TFormLipSyncArrangement.RecordEdit;
begin
  FHistory.RecordState(FProject.SaveJSON);
end;

procedure TFormLipSyncArrangement.RestoreEdit(Delta: Integer);
var
  Restored: TLipSyncProject;
begin
  if FClipPressed or FEffectPressed or (FStageGrip<>0) or FStagePanning then Exit;
  if not FTempoEditor.Finish or not FHistory.CanStep(Delta) then Exit;
  // 復元用モデルを先に生成し、失敗時は現在の作品と履歴を保持する。
  Restored := TLipSyncProject.Create('','',FHistory.Target(Delta));
  StopPlayback(False);
  FClip := nil;
  FEffect := nil;
  FSelectedTempo := -1;
  FCharacterHeaderSelected := False;
  FSelectedBounds := TRect.Empty;
  FProject.Free;
  FProject := Restored;
  FHistory.Accept(Delta);
  FSelected := Min(FSelected,FProject.Characters.Count-1);
  FAudioReady := False;
  FBPM.Text := FloatToStr(FProject.Timing.BPMAt(0));
end;

procedure TFormLipSyncArrangement.BPMKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key <> VK_RETURN then Exit;
  CommitBPM(Sender);
  Key := 0;
end;

procedure TFormLipSyncArrangement.OpenPSD;
var
  Character: TLipSyncCharacter;
  Music: string;
begin
  if (FProject = nil) or Assigned(FPsdEditor) or (FSelected<0) then Exit;
  StopPlayback(False);
  Character := FProject.Characters[FSelected];
  Music := FProject.AudioPath;
  if Assigned(FClip) then Music := FClip.Path;
  FPsdEditor := TFormLipSyncSettings.Create(Self);
  try
    FPsdEditor.BorderStyle := bsNone;
    FPsdEditor.Parent := FEditorPanel;
    FPsdEditor.Align := alClient;
    FPsdEditor.SetEmbedded;
    FPsdEditor.LoadSettings(Character.PSDPath,Music,Character.Settings,
      procedure(const PSDPath, MusicPath, JSON: string)
      begin
        Character.UpdateSettings(PSDPath,JSON);
        RecordEdit;
      end);
    SetEditorVisible(True);
    FPsdEditor.Show;
  except
    FreeAndNil(FPsdEditor);
    SetEditorVisible(False);
    raise;
  end;
end;

// フォームを閉じる際に、ホストのオブジェクトへ現在の設定を反映する。
procedure TFormLipSyncArrangement.SaveProject;
var
  PSDPath: string;
begin
  CommitBPM(FBPM);
  PSDPath := '';
  if FProject.Characters.Count>0 then PSDPath := FProject.Characters[0].PSDPath;
  FApply(PSDPath,FProject.AudioPath,FProject.SaveJSON);
end;

end.

