unit SYNC_LipSync_TimelineView;

// 統合編集タイムラインの座標変換と描画を担当する。クリップや区間は変更しない。

interface

uses
  Vcl.Graphics, SYNC_LipSync_Project;

const
  HEADER_WIDTH = 192;
  RULER_HEIGHT = 28;

type
  // 0行目は固定音源。TopRowは先頭に表示するキャラクターの0始まりインデックス。
  TLipSyncTimelineView = record
    StartBeat, PixelsPerBeat: Double;
    TopRow, RowHeight: Integer;
    function BeatAt(X: Integer): Double;
    function XAt(Beat: Double): Integer;
    function RowAt(Y: Integer): Integer;
    function RowY(Row: Integer): Integer;
    function EffectHeight: Integer;
    function CharacterHeight: Integer;
    function EffectY(Row: Integer; Lane: TLipSyncEffectLane): Integer;
  end;

  // ポインターはフォームから描画中だけ借用する。ドラッグ候補は未保存の表示用データ。
  TLipSyncTimelinePaintState = record
    Selected: Integer;
    Clip: TLipSyncClip;
    Effect: TLipSyncEffect;
    CursorSeconds: Double;
    ClipDragging, EffectDragging, EffectCreating: Boolean;
    DragRow, EffectRow: Integer;
    DragBeat, EffectFrom, EffectTo: Double;
    EffectLane: TLipSyncEffectLane;
  end;

// Canvasはフォーム所有の裏バッファ。プロジェクトは参照し、必要時に縮小画像だけ生成する。
procedure PaintLipSyncTimeline(C: TCanvas; W,H: Integer; AFont: TFont;
  Project: TLipSyncProject; const View: TLipSyncTimelineView;
  const State: TLipSyncTimelinePaintState);

implementation

uses
  Winapi.Windows, System.SysUtils, System.Types, System.Math, System.JSON,
  SYNC_LipSync_Scene, SYNC_MusicStudio_AudioWaveform, SYNC_MusicStudio_HostBackground,
  SYNC_MusicStudio_MotionData, SYNC_MusicStudio_SingingData, SYNC_LipSync_Presentation;


function TLipSyncTimelineView.BeatAt(X: Integer): Double;
begin
  Result := EnsureRange(StartBeat + (X - HEADER_WIDTH) / PixelsPerBeat,
    0.0, 1000000.0);
end;

function TLipSyncTimelineView.XAt(Beat: Double): Integer;
begin
  Result := HEADER_WIDTH + Round(EnsureRange((Beat - StartBeat) * PixelsPerBeat,
    -100000000.0, 100000000.0));
end;

function TLipSyncTimelineView.RowAt(Y: Integer): Integer;
begin
  if Y < RULER_HEIGHT then Exit(-1);
  if Y < RULER_HEIGHT + RowHeight then Exit(0);
  Result := 1 + (Y - RULER_HEIGHT - RowHeight) div CharacterHeight + TopRow;
end;

function TLipSyncTimelineView.RowY(Row: Integer): Integer;
begin
  if Row = 0 then Result := RULER_HEIGHT
  else Result := RULER_HEIGHT + RowHeight + (Row-1-TopRow)*CharacterHeight;
end;

function TLipSyncTimelineView.EffectHeight: Integer;
begin
  Result := Max(23,RowHeight div 3);
end;

function TLipSyncTimelineView.CharacterHeight: Integer;
begin
  Result := RowHeight+(Ord(High(TLipSyncEffectLane))+1)*EffectHeight;
end;

function TLipSyncTimelineView.EffectY(Row: Integer; Lane: TLipSyncEffectLane): Integer;
begin
  Result := RowY(Row)+RowHeight+Ord(Lane)*EffectHeight;
end;

procedure PaintEffects(Canvas: TCanvas; Width,Height: Integer; Project: TLipSyncProject;
  const View: TLipSyncTimelineView; const State: TLipSyncTimelinePaintState);
var
  Row, Y, X1, X2: Integer;
  Effect: TLipSyncEffect;
  R: TRect;
  Text: string;
begin
  for Row := 1+View.TopRow to Project.Characters.Count do
  begin
    if View.RowY(Row)>=Height then Break;
    for Effect in Project.Characters[Row-1].Effects do
    begin
      if State.EffectDragging and (Effect=State.Effect) then
      begin
        X1 := Max(HEADER_WIDTH,View.XAt(State.EffectFrom));
        X2 := Min(Width,View.XAt(State.EffectTo));
      end
      else
      begin
        X1 := Max(HEADER_WIDTH,View.XAt(Effect.StartBeat));
        X2 := Min(Width,View.XAt(Effect.EndBeat));
      end;
      if X1>=X2 then Continue;
      Y := View.EffectY(Row,Effect.Lane);
      R := Rect(X1,Y+2,X2,Y+View.EffectHeight-2);
      Canvas.Brush.Color := $00614A57;
      if Effect.Lane=elMotion then Canvas.Brush.Color := $004D6144;
      if Effect.Lane=elPresentation then Canvas.Brush.Color := $004A6573;
      if Effect=State.Effect then Canvas.Brush.Color := $00806036;
      Canvas.FillRect(R);
      if Effect.Lane=elExpression then
      begin
        if Effect.Visibility.Count=0 then Text := '表情（未設定）' else Text := '表情';
      end
      else if Effect.Lane=elMotion then
        Text := MusicStudioRhythmCaption(Effect.Motion)
      else
        Text := LipSyncPresentationCaption(Effect.Presentation);
      Canvas.Brush.Style := bsClear;
      Canvas.TextRect(R,R.Left+4,R.Top+2,Text);
      Canvas.Brush.Style := bsSolid;
    end;
  end;
  if State.EffectDragging and State.EffectCreating then
  begin
    Y := View.EffectY(State.EffectRow,State.EffectLane);
    Canvas.Brush.Color := $007B5B3B;
    Canvas.FillRect(Rect(View.XAt(State.EffectFrom),Y+2,View.XAt(State.EffectTo),Y+View.EffectHeight-2));
  end;
end;

procedure PaintLipSyncTimeline(C: TCanvas; W,H: Integer; AFont: TFont;
  Project: TLipSyncProject; const View: TLipSyncTimelineView;
  const State: TLipSyncTimelinePaintState);
var
  Row, Y, X, A, B, I, J, LowY, HighY, Save, Measure: Integer;
  Lane: TLipSyncEffectLane;
  Beat, Start, Duration, MinValue, MaxValue: Double;
  R, Thumb, Body: TRect;
  Character: TLipSyncCharacter;
  Clip: TLipSyncClip;
  Note: TMusicStudioSingingNote;
  Audio: SYNC_MusicStudio_AudioWaveform.TMusicStudioWaveJob;
  Text: string;
begin
  C.Font.Assign(AFont);
  C.Font.Color := $00E6E6E6;
  C.Brush.Color := $00232323;
  C.FillRect(Rect(0, 0, W, H));
  C.Brush.Color := $00383838;
  C.FillRect(Rect(0, 0, W, RULER_HEIGHT));
  C.TextOut(8, 6, 'トラック / 小節・拍');

  Row := 0;
  while Row <= Project.Characters.Count do
  begin
    Y := View.RowY(Row);
    if Y >= H then Break;
    C.Brush.Color := $002D2D2D;
    if (Row > 0) and (Row - 1 = State.Selected) then C.Brush.Color := $00544535;
    C.FillRect(Rect(0, Y, HEADER_WIDTH, Y + View.RowHeight - 1));
    if Row = 0 then
    begin
      C.TextOut(8, Y + 8, '1  基準音源 (WAV / MP3)');
      C.TextRect(Rect(0,Y,HEADER_WIDTH,Y+View.RowHeight),8,Y+34,ExtractFileName(Project.AudioPath));
    end
    else
    begin
      Character := Project.Characters[Row - 1];
      C.TextRect(Rect(0,Y,HEADER_WIDTH,Y+View.RowHeight),8,Y+8,
        IntToStr(Row + 1) + '  ' + ExtractFileName(Character.PSDPath));
      Character.EnsureThumbnail;
      if not Character.Thumbnail.Empty then
      begin
        Thumb := MusicStudioFitFrameRect(Rect(8,Y+29,65,Y+View.RowHeight-3),
          Character.Thumbnail.Width, Character.Thumbnail.Height);
        C.StretchDraw(Thumb, Character.Thumbnail);
      end;
    end;
    C.Pen.Color := $00404040;
    C.MoveTo(0, Y + View.RowHeight - 1);
    C.LineTo(W, Y + View.RowHeight - 1);
    if Row = 0 then Row := 1 + View.TopRow
    else
    begin
      for Lane := Low(Lane) to High(Lane) do
      begin
        Y := View.EffectY(Row,Lane);
        C.Brush.Color := $00282828;
        C.FillRect(Rect(0,Y,HEADER_WIDTH,Y+View.EffectHeight-1));
        case Lane of
          elExpression: Text := '表情';
          elMotion: Text := 'アニメーション';
          elPresentation: Text := '演出';
        end;
        C.TextOut(24,Y+3,Text);
        C.Pen.Color := $003C3C3C;
        C.MoveTo(0,Y+View.EffectHeight-1);
        C.LineTo(W,Y+View.EffectHeight-1);
      end;
      Inc(Row);
    end;
  end;

  Save := SaveDC(C.Handle);
  try
    IntersectClipRect(C.Handle, HEADER_WIDTH, 0, W, H);
    C.Brush.Style := bsClear;
    Measure := Project.Timing.MeasureAtBeat(View.BeatAt(HEADER_WIDTH));
    Beat := Project.Timing.MeasureStart(Measure);
    while View.XAt(Beat) < W do
    begin
      X := View.XAt(Beat);
      C.Pen.Color := $005A5A5A;
      C.MoveTo(X, 0); C.LineTo(X, H);
      C.TextOut(X + 4, 5, IntToStr(Measure));
      Start := Beat + 4 / Project.Timing.DenominatorAtBeat(Beat);
      while (Start < Beat + Project.Timing.MeasureLengthAtBeat(Beat) - 1E-8) and
        (View.XAt(Start) < W) do
      begin
        X := View.XAt(Start);
        C.Pen.Color := $00383838;
        C.MoveTo(X, RULER_HEIGHT); C.LineTo(X, H);
        C.TextOut(X + 3, 5, '·');
        Start := Start + 4 / Project.Timing.DenominatorAtBeat(Beat);
      end;
      Inc(Measure);
      Beat := Project.Timing.MeasureStart(Measure);
    end;
    C.Brush.Style := bsSolid;
    Audio := Project.Audio;
    if Assigned(Audio) and Audio.Done and (Length(Audio.Waveform) > 0) then
    begin
      Duration := Audio.Info.Duration;
      C.Pen.Color := $00C9A86E;
      for X := HEADER_WIDTH to Min(W - 1, View.XAt(Project.Timing.SecondsToBeat(Duration))) do
      begin
        A := EnsureRange(Floor(Project.Timing.BeatToSeconds(View.BeatAt(X)) * Length(Audio.Waveform) / Duration),0,High(Audio.Waveform));
        B := EnsureRange(Ceil(Project.Timing.BeatToSeconds(View.BeatAt(X+1)) * Length(Audio.Waveform) / Duration),A,High(Audio.Waveform));
        MinValue := 0; MaxValue := 0;
        for I := A to B do
        begin
          MinValue := Min(MinValue, Audio.Waveform[I].Minimum);
          MaxValue := Max(MaxValue, Audio.Waveform[I].Maximum);
        end;
        LowY := RULER_HEIGHT + View.RowHeight div 2 - Round(MaxValue * (View.RowHeight / 2 - 5));
        HighY := RULER_HEIGHT + View.RowHeight div 2 - Round(MinValue * (View.RowHeight / 2 - 5));
        C.MoveTo(X, LowY); C.LineTo(X, HighY + 1);
      end;
    end;

    for Row := 1 + View.TopRow to Project.Characters.Count do
    begin
      Y := View.RowY(Row);
      if Y >= H then Break;
      for Clip in Project.Characters[Row-1].Clips do
      begin
        if State.ClipDragging and (State.DragRow > 0) and (Clip = State.Clip) then Continue;
        A := View.XAt(Clip.Beat);
        B := View.XAt(Project.EndBeat(Clip));
        if (B <= HEADER_WIDTH) or (A >= W) then Continue;
        R := Rect(Max(A,HEADER_WIDTH),Y+3,Min(B,W),Y+View.RowHeight-3);
        C.Brush.Color := $00574733;
        if Clip = State.Clip then C.Brush.Color := $00806036;
        C.FillRect(R);
        Text := ExtractFileName(Clip.Path);
        if Clip.Track < 0 then Text := Text + '（歌詞なし）';
        C.Brush.Style := bsClear;
        C.TextRect(R, Max(A+4,HEADER_WIDTH+2),Y+6,Text);
        Start := Project.Timing.BeatToSeconds(Clip.Beat);
        for Note in Clip.Source.Notes do
          if (Note.TrackIndex = Clip.Track) and (Note.Lyric <> '') then
          begin
            I := View.XAt(Project.Timing.SecondsToBeat(Start + Note.StartSeconds));
            J := View.XAt(Project.Timing.SecondsToBeat(Start + Note.EndSeconds));
            Body := Rect(Max(I,R.Left),Y+25,Min(Max(I+1,J),R.Right),Y+View.RowHeight-5);
            if Body.IsEmpty then Continue;
            C.Pen.Color := $00A08361;
            C.MoveTo(Body.Left, Body.Top); C.LineTo(Body.Right, Body.Top);
            C.TextRect(Body, Body.Left+2, Body.Top+2, Note.Lyric);
            C.TextRect(Body, Body.Left+2, Body.Top+19, LipSyncVowelCaption(Note.Vowels));
          end;
        C.Brush.Style := bsSolid;
      end;
    end;
    if State.ClipDragging and (State.DragRow > 0) and Assigned(State.Clip) then
    begin
      Y := View.RowY(State.DragRow);
      X := View.XAt(State.DragBeat);
      B := View.XAt(Project.Timing.SecondsToBeat(Project.Timing.BeatToSeconds(State.DragBeat) + State.Clip.Source.Duration));
      C.Brush.Color := $007B5B3B;
      C.FillRect(Rect(X, Y+3, Max(X+8,B), Y+View.RowHeight-3));
    end;
    PaintEffects(C,W,H,Project,View,State);
    X := View.XAt(Project.Timing.SecondsToBeat(State.CursorSeconds));
    C.Pen.Color := $0084BFF0;
    C.MoveTo(X,0); C.LineTo(X,H);
  finally
    RestoreDC(C.Handle,Save);
  end;
end;

end.
