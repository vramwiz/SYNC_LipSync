unit SYNC_MusicStudio_SingingData;

// SongReaderSMFのMIDI/KARイベント読込方式を複製し、境界検証と全トラック共通テンポで適応。
// 音符・歌詞・母音は読込中の表示用のみ。JSONへはファイル参照と利用トラック番号を保存する。
interface

uses
  System.Classes, System.SyncObjs;

type
  TMusicStudioSingingStatus = (ssEmpty, ssReady, ssNoLyrics, ssUnsupported, ssMissing, ssBroken);
  TMusicStudioSingingNote = record
    StartSeconds, EndSeconds: Double;
    TrackIndex, Channel, Key, Velocity: Integer;
    Lyric, Vowels: string;
  end;
  TMusicStudioSingingNotes = TArray<TMusicStudioSingingNote>;
  TMusicStudioSingingTrack = record
    Index: Integer;
    Name: string;
    NoteCount, LyricCount: Integer;
    Duration: Double;
  end;
  TMusicStudioSingingSource = record
    Status: TMusicStudioSingingStatus;
    Message: string;
    Tracks: TArray<TMusicStudioSingingTrack>;
    Notes: TMusicStudioSingingNotes;
    Duration: Double;
  end;
  TMusicStudioSingingJob = class(TThread)
  private
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    FilePath: string;
    RequestID: Integer;
    Source: TMusicStudioSingingSource;
    constructor Create(const Path: string; ID: Integer);
    destructor Destroy; override;
    function Done: Boolean;
  end;

// 上限32MiB、SMF0/1のPPQ MIDI/KARを読む。取消時に部分結果を返さない。
function LoadMusicStudioSinging(const Path: string; Cancel: TThread = nil): TMusicStudioSingingSource;

implementation

uses
  System.SysUtils, System.Math, System.IOUtils, System.Generics.Collections,
  System.Generics.Defaults, SYNC_MusicStudio_Vowels, SYNC_MusicStudio_SingingFormats;

type
  TThreadAccess = class(TThread);
  EMidiUnsupported = class(Exception);
  TRawNote = record
    Tick, EndTick: Int64;
    Track, Channel, Key, Velocity: Integer;
    Lyric: string;
  end;
  TTempo = record
    Tick: Int64;
    Order: Integer;
    Microseconds: Integer;
    Seconds: Double;
  end;
  TMetaLyric = record
    Tick: Int64;
    Track: Integer;
    Text: string;
    ExplicitLyric: Boolean;
  end;
  TBoundedMidiReader = class
  private
    FData: TBytes;
    FPos, FLimit, FDivision, FEvents: Integer;
    FCancel: TThread;
    FAllowKarText: Boolean;
    FRawNotes: TList<TRawNote>;
    FTempos: TList<TTempo>;
    FLyrics: TList<TMetaLyric>;
    FTrackNames: TArray<string>;
    function ByteValue: Byte;
    function Big16: Word;
    function Big32: Cardinal;
    function VLQ: Cardinal;
    function TextBytes(Count: Integer): TBytes;
    procedure Skip(Count: Integer);
    function Tag: AnsiString;
    procedure ReadTrack(Index: Integer);
    procedure AssociateLyrics;
    function TickToSeconds(Tick: Int64): Double;
  public
    constructor Create(const Data: TBytes; Cancel: TThread; AllowKarText: Boolean);
    destructor Destroy; override;
    function Parse: TMusicStudioSingingSource;
  end;

function DecodeMidiText(const Bytes: TBytes): string;
var
  Encoding: TEncoding;
begin
  // TextEncodingUtilsのUTF-8優先/Shift-JISフォールバックを境界付き入力に適応。
  if Length(Bytes) = 0 then Exit('');
  if TEncoding.UTF8.IsBufferValid(@Bytes[0], Length(Bytes)) then
    Result := TEncoding.UTF8.GetString(Bytes)
  else begin
    Encoding := TEncoding.GetEncoding(932);
    try Result := Encoding.GetString(Bytes); finally Encoding.Free; end;
  end;
  Result := StringReplace(Result, #0, '', [rfReplaceAll]);
end;

constructor TBoundedMidiReader.Create(const Data: TBytes; Cancel: TThread; AllowKarText: Boolean);
begin
  inherited Create;
  FData := Data;
  FLimit := Length(Data);
  FCancel := Cancel;
  FAllowKarText := AllowKarText;
  FRawNotes := TList<TRawNote>.Create;
  FTempos := TList<TTempo>.Create;
  FLyrics := TList<TMetaLyric>.Create;
end;

destructor TBoundedMidiReader.Destroy;
begin
  FLyrics.Free;
  FTempos.Free;
  FRawNotes.Free;
  inherited;
end;

function TBoundedMidiReader.ByteValue: Byte;
begin
  if FPos >= FLimit then raise Exception.Create('MIDIイベントが途中で切れています。');
  Result := FData[FPos];
  Inc(FPos);
end;

function TBoundedMidiReader.Big16: Word;
begin
  Result := Word(ByteValue) shl 8;
  Result := Result or ByteValue;
end;

function TBoundedMidiReader.Big32: Cardinal;
begin
  Result := Cardinal(Big16) shl 16;
  Result := Result or Big16;
end;

function TBoundedMidiReader.VLQ: Cardinal;
var
  I: Integer;
  Value: Byte;
begin
  Result := 0;
  for I := 1 to 4 do
  begin
    Value := ByteValue;
    Result := (Result shl 7) or (Value and $7F);
    if Value and $80 = 0 then Exit;
  end;
  raise Exception.Create('MIDI可変長値が4バイトを超えています。');
end;

procedure TBoundedMidiReader.Skip(Count: Integer);
begin
  if (Count < 0) or (Count > FLimit - FPos) then
    raise Exception.Create('MIDIチャンクの長さが不正です。');
  Inc(FPos, Count);
end;

function TBoundedMidiReader.TextBytes(Count: Integer): TBytes;
var
  Start: Integer;
begin
  Start := FPos;
  Skip(Count);
  Result := Copy(FData, Start, Count);
end;

function TBoundedMidiReader.Tag: AnsiString;
var
  I: Integer;
begin
  SetLength(Result, 4);
  for I := 1 to 4 do Result[I] := AnsiChar(ByteValue);
end;

procedure TBoundedMidiReader.ReadTrack(Index: Integer);
var
  TrackEnd, OriginalLimit, LengthValue, Data1, Data2, NoteIndex, KeyValue: Integer;
  Tick: Int64;
  Status, Running, MetaType: Byte;
  Ended: Boolean;
  Raw: TRawNote;
  Lyric: TMetaLyric;
  Tempo: TTempo;
  Bytes: TBytes;
  Active: TObjectDictionary<Integer, TQueue<Integer>>;
  Queue: TQueue<Integer>;
begin
  if Tag <> 'MTrk' then raise Exception.Create('MIDIのMTrkチャンクがありません。');
  LengthValue := Big32;
  if (LengthValue < 0) or (LengthValue > FLimit - FPos) then
    raise Exception.Create('MIDIトラックの長さが不正です。');
  TrackEnd := FPos + LengthValue;
  OriginalLimit := FLimit;
  FLimit := TrackEnd;
  Tick := 0;
  Running := 0;
  Ended := False;
  Active := TObjectDictionary<Integer, TQueue<Integer>>.Create([doOwnsValues]);
  try
    while FPos < TrackEnd do
    begin
      if Assigned(FCancel) and TThreadAccess(FCancel).Terminated then raise EAbort.Create('取消');
      Inc(FEvents);
      if FEvents > 1000000 then raise Exception.Create('MIDIイベント数の上限を超えています。');
      Inc(Tick, VLQ);
      if Tick > 1000000000 then raise Exception.Create('MIDI時刻が上限を超えています。');
      Status := ByteValue;
      if Status = $FF then
      begin
        Running := 0;
        MetaType := ByteValue;
        LengthValue := VLQ;
        if (MetaType in [$01,$03,$05]) and (LengthValue > 65536) then
          raise Exception.Create('MIDI文字イベントが64KiBを超えています。');
        Bytes := TextBytes(LengthValue);
        case MetaType of
          $2F: begin
            if LengthValue <> 0 then raise Exception.Create('MIDI終端イベントが不正です。');
            Ended := True;
            if FPos <> TrackEnd then raise Exception.Create('MIDI終端後に余分なイベントがあります。');
            Break;
          end;
          $03: FTrackNames[Index] := DecodeMidiText(Bytes);
          $01, $05: begin
            Lyric := Default(TMetaLyric);
            Lyric.Tick := Tick; Lyric.Track := Index;
            Lyric.Text := Trim(DecodeMidiText(Bytes));
            if (MetaType = $01) and (Pos('@KMIDI',UpperCase(Lyric.Text)) = 1) then FAllowKarText := True;
            Lyric.ExplicitLyric := MetaType = $05;
            if (Lyric.Text <> '') and (Lyric.Text[1] <> '@') then
            begin
              while (Lyric.Text <> '') and CharInSet(Lyric.Text[1], ['\', '/']) do Delete(Lyric.Text, 1, 1);
              if Trim(Lyric.Text) <> '' then FLyrics.Add(Lyric);
            end;
          end;
          $51: begin
            if LengthValue <> 3 then raise Exception.Create('MIDIテンポイベントが不正です。');
            Tempo := Default(TTempo);
            Tempo.Tick := Tick;
            Tempo.Order := FTempos.Count;
            Tempo.Microseconds := (Integer(Bytes[0]) shl 16) or (Integer(Bytes[1]) shl 8) or Bytes[2];
            if Tempo.Microseconds = 0 then raise Exception.Create('MIDIテンポが0です。');
            FTempos.Add(Tempo);
          end;
        end;
        Continue;
      end;
      if (Status = $F0) or (Status = $F7) then
      begin
        Running := 0;
        Skip(VLQ);
        Continue;
      end;
      if Status < $80 then
      begin
        if Running = 0 then raise Exception.Create('MIDIランニングステータスがありません。');
        Data1 := Status; Status := Running;
      end
      else
      begin
        if Status >= $F0 then raise Exception.Create('SMFでは扱えないシステムイベントです。');
        Running := Status;
        Data1 := ByteValue;
      end;
      if Data1 >= $80 then raise Exception.Create('MIDIデータバイトが不正です。');
      Data2 := 0;
      if not ((Status and $F0) in [$C0, $D0]) then Data2 := ByteValue;
      if Data2 >= $80 then raise Exception.Create('MIDIデータバイトが不正です。');
      KeyValue := (Status and $0F) * 128 + Data1;
      if ((Status and $F0) = $90) and (Data2 > 0) then
      begin
        Raw := Default(TRawNote);
        Raw.Tick := Tick; Raw.EndTick := -1; Raw.Track := Index;
        Raw.Channel := Status and $0F; Raw.Key := Data1; Raw.Velocity := Data2;
        NoteIndex := FRawNotes.Add(Raw);
        if not Active.TryGetValue(KeyValue, Queue) then
        begin Queue := TQueue<Integer>.Create; Active.Add(KeyValue, Queue); end;
        Queue.Enqueue(NoteIndex);
      end
      else if ((Status and $F0) = $80) or (((Status and $F0) = $90) and (Data2 = 0)) then
        if Active.TryGetValue(KeyValue, Queue) and (Queue.Count > 0) then
        begin
          NoteIndex := Queue.Dequeue;
          Raw := FRawNotes[NoteIndex]; Raw.EndTick := Tick;
          FRawNotes[NoteIndex] := Raw;
        end;
    end;
    if not Ended then raise Exception.Create('MIDIのEndOfTrackがありません。');
    for Queue in Active.Values do
      while Queue.Count > 0 do
      begin
        NoteIndex := Queue.Dequeue;
        Raw := FRawNotes[NoteIndex];
        Raw.EndTick := Max(Raw.Tick + 1, Tick);
        FRawNotes[NoteIndex] := Raw;
      end;
  finally
    FLimit := OriginalLimit;
    Active.Free;
  end;
end;

procedure TBoundedMidiReader.AssociateLyrics;
var
  Lyric: TMetaLyric;
  ExplicitTracks: TArray<Boolean>;
  I, Candidate, Lo, Hi, Mid: Integer;
  Starts, Ends: TArray<Integer>;
  Raw: TRawNote;
begin
  SetLength(ExplicitTracks, Length(FTrackNames));
  SetLength(Starts, Length(FTrackNames));
  SetLength(Ends, Length(FTrackNames));
  for I := 0 to High(Starts) do begin Starts[I] := -1; Ends[I] := -1; end;
  // 各トラックを順に読むので、同一トラックの音符は連続し開始tick順に並ぶ。
  for I := 0 to FRawNotes.Count - 1 do
  begin
    if (I mod 512 = 0) and Assigned(FCancel) and TThreadAccess(FCancel).Terminated then raise EAbort.Create('取消');
    Raw := FRawNotes[I];
    if Starts[Raw.Track] < 0 then Starts[Raw.Track] := I;
    Ends[Raw.Track] := I + 1;
  end;
  for Lyric in FLyrics do if Lyric.ExplicitLyric then ExplicitTracks[Lyric.Track] := True;
  for Lyric in FLyrics do
  begin
    if Assigned(FCancel) and TThreadAccess(FCancel).Terminated then raise EAbort.Create('取消');
    if ExplicitTracks[Lyric.Track] and not Lyric.ExplicitLyric then Continue;
    if not FAllowKarText and not Lyric.ExplicitLyric then Continue;
    Lo := Starts[Lyric.Track]; Hi := Ends[Lyric.Track];
    if Lo < 0 then Continue;
    while Lo < Hi do
    begin
      Mid := Lo + (Hi - Lo) div 2;
      if FRawNotes[Mid].Tick < Lyric.Tick then Lo := Mid + 1 else Hi := Mid;
    end;
    Candidate := Lo;
    if Candidate >= Ends[Lyric.Track] then Continue;
    Raw := FRawNotes[Candidate];
    if Length(Raw.Lyric) + Length(Lyric.Text) > 1024 then
      raise Exception.Create('1音符の歌詞が1024文字を超えています。');
    Raw.Lyric := Raw.Lyric + Lyric.Text;
    FRawNotes[Candidate] := Raw;
  end;
end;

function TBoundedMidiReader.TickToSeconds(Tick: Int64): Double;
var
  I, Lo, Hi, Mid: Integer;
  BaseTick: Int64;
  BaseSeconds: Double;
  Microseconds: Integer;
begin
  BaseTick := 0; BaseSeconds := 0; Microseconds := 500000;
  Lo := 0; Hi := FTempos.Count;
  while Lo < Hi do
  begin
    Mid := Lo + (Hi - Lo) div 2;
    if FTempos[Mid].Tick <= Tick then Lo := Mid + 1 else Hi := Mid;
  end;
  I := Lo - 1;
  if I >= 0 then
  begin
    BaseTick := FTempos[I].Tick;
    BaseSeconds := FTempos[I].Seconds;
    Microseconds := FTempos[I].Microseconds;
  end;
  Result := BaseSeconds + (Tick - BaseTick) / FDivision * Microseconds / 1000000;
end;

function TBoundedMidiReader.Parse: TMusicStudioSingingSource;
var
  HeaderLength: Cardinal;
  FormatType, TrackCount: Word;
  I, LyricCount: Integer;
  Tempo, PreviousTempo: TTempo;
  Raw: TRawNote;
  Note: TMusicStudioSingingNote;
  PreviousVowels: TArray<string>;
  Lyric: TMetaLyric;
  HasLyrics: Boolean;
begin
  Result := Default(TMusicStudioSingingSource);
  if Tag <> 'MThd' then raise Exception.Create('MIDIのMThdヘッダーがありません。');
  HeaderLength := Big32;
  if (HeaderLength < 6) or (HeaderLength > Cardinal(FLimit - FPos)) then
    raise Exception.Create('MIDIヘッダー長が不正です。');
  FormatType := Big16; TrackCount := Big16; FDivision := Big16;
  if FormatType > 1 then raise EMidiUnsupported.Create('SMF形式0/1のみ対応しています。形式2は未対応です。');
  if (FDivision and $8000) <> 0 then raise EMidiUnsupported.Create('SMPTE時間基準のMIDIは未対応です。PPQ形式を使用してください。');
  if (FDivision = 0) or (TrackCount < 1) or (TrackCount > 256) or
    ((FormatType = 0) and (TrackCount <> 1)) then raise Exception.Create('MIDIトラック数または時間分解能が不正です。');
  Skip(HeaderLength - 6);
  SetLength(FTrackNames, TrackCount);
  for I := 0 to TrackCount - 1 do ReadTrack(I);
  if FPos <> Length(FData) then raise Exception.Create('MIDIトラック末尾に余分なデータがあります。');
  FTempos.Sort(TComparer<TTempo>.Construct(
    function(const Left, Right: TTempo): Integer
    begin
      if Left.Tick < Right.Tick then Exit(-1);
      if Left.Tick > Right.Tick then Exit(1);
      Result := Left.Order - Right.Order;
    end));
  PreviousTempo := Default(TTempo); PreviousTempo.Microseconds := 500000;
  for I := 0 to FTempos.Count - 1 do
  begin
    Tempo := FTempos[I];
    Tempo.Seconds := PreviousTempo.Seconds + (Tempo.Tick - PreviousTempo.Tick) /
      FDivision * PreviousTempo.Microseconds / 1000000;
    FTempos[I] := Tempo; PreviousTempo := Tempo;
  end;
  AssociateLyrics;
  SetLength(Result.Tracks, TrackCount);
  SetLength(Result.Notes, FRawNotes.Count);
  SetLength(PreviousVowels, TrackCount);
  for I := 0 to TrackCount - 1 do
  begin Result.Tracks[I].Index := I; Result.Tracks[I].Name := FTrackNames[I]; end;
  LyricCount := 0;
  for I := 0 to FRawNotes.Count - 1 do
  begin
    Raw := FRawNotes[I];
    Note := Default(TMusicStudioSingingNote);
    if (I mod 512 = 0) and Assigned(FCancel) and TThreadAccess(FCancel).Terminated then raise EAbort.Create('取消');
    Note.StartSeconds := TickToSeconds(Raw.Tick);
    Note.EndSeconds := TickToSeconds(Max(Raw.Tick + 1, Raw.EndTick));
    if Note.EndSeconds > 604800 then raise Exception.Create('MIDIの長さが上限604800秒を超えています。');
    Note.TrackIndex := Raw.Track; Note.Channel := Raw.Channel; Note.Key := Raw.Key;
    Note.Velocity := Raw.Velocity; Note.Lyric := Raw.Lyric;
    Note.Vowels := MusicStudioLyricVowels(Raw.Lyric, PreviousVowels[Raw.Track]);
    if Note.Vowels <> '' then PreviousVowels[Raw.Track] := Note.Vowels;
    Result.Notes[I] := Note;
    Inc(Result.Tracks[Raw.Track].NoteCount);
    if Raw.Lyric <> '' then begin Inc(Result.Tracks[Raw.Track].LyricCount); Inc(LyricCount); end;
    Result.Tracks[Raw.Track].Duration := Max(Result.Tracks[Raw.Track].Duration, Note.EndSeconds);
    Result.Duration := Max(Result.Duration, Note.EndSeconds);
  end;
  if LyricCount = 0 then
  begin
    Result.Status := ssNoLyrics;
    HasLyrics := False;
    for Lyric in FLyrics do if Lyric.ExplicitLyric or FAllowKarText then HasLyrics := True;
    if HasLyrics then Result.Message := '歌詞イベントはありますが、同じトラックの音符に対応しません。歌詞と音符を同じトラックにまとめたMIDIを使用してください。'
    else Result.Message := 'MIDIは読み込めましたが、音符に対応する歌詞がありません。';
  end
  else begin Result.Status := ssReady; Result.Message := Format('歌詞付き音符 %d件 / %dトラック', [LyricCount, TrackCount]); end;
end;

function LoadMusicStudioSinging(const Path: string; Cancel: TThread): TMusicStudioSingingSource;
var
  Ext: string;
  Stream: TFileStream;
  Bytes: TBytes;
  Reader: TBoundedMidiReader;
begin
  Result := Default(TMusicStudioSingingSource);
  if Path = '' then begin Result.Status := ssEmpty; Result.Message := '歌唱データを選択してください。'; Exit; end;
  Ext := LowerCase(ExtractFileExt(Path));
  if not ((Ext = '.mid') or (Ext = '.midi') or (Ext = '.kar') or MusicStudioStructuredSong(Ext)) then
  begin Result.Status := ssUnsupported; Result.Message := '未対応形式です。MIDI/KAR・UST・VSQX・MusicXML・MuseScoreを指定してください。'; Exit; end;
  if not TFile.Exists(Path) then begin Result.Status := ssMissing; Result.Message := '参照先の歌唱ファイルが見つかりません。'; Exit; end;
  try
    if MusicStudioStructuredSong(Ext) then Exit(LoadMusicStudioStructuredSong(Path,Cancel));
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      if (Stream.Size < 14) or (Stream.Size > 32 * 1024 * 1024) then raise Exception.Create('MIDIのサイズが不正、または32MiBを超えています。');
      SetLength(Bytes, Stream.Size);
      Stream.ReadBuffer(Bytes[0], Length(Bytes));
    finally Stream.Free; end;
    Reader := TBoundedMidiReader.Create(Bytes, Cancel, Ext = '.kar');
    try Result := Reader.Parse; finally Reader.Free; end;
  except
    on E: EMidiUnsupported do begin Result.Status := ssUnsupported; Result.Message := E.Message; end;
    on E: EAbort do begin Result := Default(TMusicStudioSingingSource); Result.Status := ssEmpty; Result.Message := '読み込みを取り消しました。'; end;
    on E: Exception do begin Result := Default(TMusicStudioSingingSource); Result.Status := ssBroken; Result.Message := '歌唱データを読み込めません: ' + E.Message; end;
  end;
end;

constructor TMusicStudioSingingJob.Create(const Path: string; ID: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FilePath := Path; RequestID := ID;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TMusicStudioSingingJob.Destroy;
begin
  Terminate; WaitFor; FDone.Free;
  inherited;
end;

function TMusicStudioSingingJob.Done: Boolean;
begin Result := (FDone.WaitFor(0) = wrSignaled) or Finished; end;

procedure TMusicStudioSingingJob.Execute;
begin
  try Source := LoadMusicStudioSinging(FilePath, Self);
  finally FDone.SetEvent; end;
end;

end.
