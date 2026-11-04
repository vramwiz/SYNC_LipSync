unit SYNC_LipSync_TempoEditor;

// テンポマーカーの位置にBPM入力欄を表示する。確定処理はフォームに委譲する。

interface

uses System.Classes, Vcl.ExtCtrls, Vcl.StdCtrls, SYNC_LipSync_TimelineView;

type
  TLipSyncTempoCommit = procedure(Beat,BPM: Double) of object;

  TLipSyncTempoEditor = class
  private
    FTimeline: TPaintBox;
    FStatus: TLabel;
    FEdit: TEdit;
    FCommit: TLipSyncTempoCommit;
    FBeat: Double;
    FEditing: Boolean;
    procedure KeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ExitEdit(Sender: TObject);
  public
    // TimelineとStatusはフォーム所有。入力欄だけを所有する。
    constructor Create(Timeline: TPaintBox; Status: TLabel; Commit: TLipSyncTempoCommit);
    destructor Destroy; override;
    procedure Open(X: Integer; Beat,BPM: Double; const View: TLipSyncTimelineView);
    function Finish: Boolean;
    procedure Cancel;
  end;

implementation

uses Winapi.Windows, System.SysUtils, System.Math,
  SYNC_MusicStudio_DarkTheme;

constructor TLipSyncTempoEditor.Create(Timeline: TPaintBox; Status: TLabel;
  Commit: TLipSyncTempoCommit);
begin
  inherited Create;
  FTimeline := Timeline;
  FStatus := Status;
  FCommit := Commit;
  FEdit := TEdit.Create(nil);
  FEdit.Parent := Timeline.Parent;
  FEdit.Visible := False;
  FEdit.OnKeyDown := KeyDown;
  FEdit.OnExit := ExitEdit;
  ApplySyncMusicStudioDarkEdit(FEdit);
end;

destructor TLipSyncTempoEditor.Destroy;
begin
  FEditing := False;
  FEdit.Free;
  inherited;
end;

procedure TLipSyncTempoEditor.Open(X: Integer; Beat,BPM: Double; const View: TLipSyncTimelineView);
var
  EditWidth: Integer;
begin
  if not Finish then Exit;
  FBeat := Beat;
  EditWidth := View.Px(104);
  FEdit.SetBounds(FTimeline.Left+EnsureRange(X,View.HeaderWidth,Max(View.HeaderWidth,FTimeline.Width-EditWidth)),
    FTimeline.Top+View.TempoTop-View.Px(3),EditWidth,View.Px(29));
  FEdit.Text := FloatToStr(BPM);
  FEditing := True;
  FEdit.Visible := True;
  FEdit.BringToFront;
  if FEdit.Showing and FEdit.CanFocus then FEdit.SetFocus;
  FEdit.SelectAll;
end;

function TLipSyncTempoEditor.Finish: Boolean;
var
  BPM: Double;
begin
  Result := True;
  if not FEditing then Exit;
  Result := False;
  if not TryStrToFloat(FEdit.Text,BPM) or IsNan(BPM) or IsInfinite(BPM) or
    (BPM<1) or (BPM>999.99) then
  begin
    FStatus.Caption := 'BPM は 1～999.99 の範囲で入力してください。';
    Exit;
  end;
  try
    FCommit(FBeat,BPM);
    Cancel;
    Result := True;
  except
    on E: Exception do FStatus.Caption := E.Message;
  end;
end;

procedure TLipSyncTempoEditor.Cancel;
begin
  FEditing := False;
  FEdit.Visible := False;
end;

procedure TLipSyncTempoEditor.KeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_RETURN: Finish;
    VK_ESCAPE: Cancel;
  else
    Exit;
  end;
  Key := 0;
end;

procedure TLipSyncTempoEditor.ExitEdit(Sender: TObject);
begin
  Finish;
end;

end.

