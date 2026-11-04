unit SYNC_MusicStudio_AudioWaveform;

// 音源を逐次デコードしてmin/max包絡線に縮約する。音源全体のPCMや外部DLLを保持しない。
// 縮約方式は保管したSYNC_Lyrics_AudioWaveformから適応。左右逆相でも各chのピークを残す。
interface

uses
  System.Classes, System.SyncObjs;

type
  TMusicStudioWavePoint = record
    Minimum, Maximum: Single;
  end;
  TMusicStudioWaveform = TArray<TMusicStudioWavePoint>;
  TMusicStudioAudioInfo = record
    Duration: Double;
    SampleRate, Channels: Integer;
  end;
  TMusicStudioWaveJob = class(TThread)
  private
    FDone: TEvent;
    procedure Decode;
  protected
    procedure Execute; override;
  public
    FilePath: string;
    RequestID: Integer;
    Waveform: TMusicStudioWaveform;
    Info: TMusicStudioAudioInfo;
    ErrorText: string;
    // 所有者がTerminate/WaitFor/Freeする。UIへのQueueやフォーム参照を持たない。
    constructor Create(const Path: string; ID: Integer);
    destructor Destroy; override;
    function Done: Boolean;
  end;

implementation

uses
  System.SysUtils, System.Math, System.IOUtils, Winapi.Windows,
  Winapi.ActiveX, Winapi.MMSystem, Winapi.WMF9, System.Win.ComObj;

const
  BLOCK_FRAMES = 1024;
  MAX_WAVE_BLOCKS = 4000000; // 異常な長さの入力による無制限メモリ使用を防ぐ。

type
  TEnvelopeBuilder = class
  private
    FBlocks: TMusicStudioWaveform;
    FFrames: Int64;
    FCount: Integer;
  public
    procedure Append(Data: PByte; ByteCount: Integer; const Format: TWaveFormatEx;
      Cancel: TMusicStudioWaveJob);
    procedure Finish(out Wave: TMusicStudioWaveform; out Info: TMusicStudioAudioInfo;
      const Format: TWaveFormatEx);
  end;
  TRiffHeader = packed record
    Tag: array[0..3] of AnsiChar;
    Size: Cardinal;
    Kind: array[0..3] of AnsiChar;
  end;
  TChunkHeader = packed record
    Tag: array[0..3] of AnsiChar;
    Size: Cardinal;
  end;

{$WARN SYMBOL_PLATFORM OFF} // Win64専用。必要になるまでWindows標準デコーダをロードしない。
function CreateSyncReader(Cert: IUnknown; Rights: LongWord;
  out Reader: IWMSyncReader): HRESULT; stdcall;
  external 'wmvcore.dll' name 'WMCreateSyncReader' delayed;
{$WARN SYMBOL_PLATFORM ON}

procedure CheckFormat(const Format: TWaveFormatEx);
begin
  if (Format.nChannels < 1) or (Format.nChannels > 32) or
    (Format.nSamplesPerSec < 1) or (Format.nSamplesPerSec > 768000) or
    (Format.nBlockAlign <> Format.nChannels * (Format.wBitsPerSample div 8)) or
    not (((Format.wFormatTag = WAVE_FORMAT_PCM) and
      (Format.wBitsPerSample in [8, 16, 24, 32])) or
      ((Format.wFormatTag = 3) and (Format.wBitsPerSample = 32))) then
    raise Exception.Create('対応していないWAV/PCM形式です。PCM 8/16/24/32bit、float 32bitを使用してください。');
end;

function ReadSample(Data: PByte; Bits: Word; IsFloat: Boolean): Single;
var
  Signed24: Integer;
begin
  if IsFloat then Result := PSingle(Data)^ else
    case Bits of
      8: Result := (Data^ - 128) / 128.0;
      16: Result := PSmallInt(Data)^ / 32768.0;
      24: begin
        Signed24 := Integer(Data[0]) or (Integer(Data[1]) shl 8) or
          (Integer(Data[2]) shl 16);
        if (Signed24 and $800000) <> 0 then Signed24 := Signed24 - $1000000;
        Result := Signed24 / 8388608.0;
      end;
      32: Result := PInteger(Data)^ / 2147483648.0;
    else Result := 0;
    end;
  if IsNan(Result) or IsInfinite(Result) then
    raise Exception.Create('音源に不正な浮動小数点サンプルがあります。');
  Result := EnsureRange(Result, -1.0, 1.0);
end;

procedure TEnvelopeBuilder.Append(Data: PByte; ByteCount: Integer;
  const Format: TWaveFormatEx; Cancel: TMusicStudioWaveJob);
var
  Frame, Channel, Index, BytesPerSample: Integer;
  Value: Single;
begin
  if ByteCount mod Format.nBlockAlign <> 0 then
    raise Exception.Create('音声サンプルの終端が壊れています。');
  BytesPerSample := Format.wBitsPerSample div 8;
  for Frame := 0 to ByteCount div Format.nBlockAlign - 1 do
  begin
    Index := FFrames div BLOCK_FRAMES;
    if FFrames mod BLOCK_FRAMES = 0 then
    begin
      if Cancel.Terminated then Exit;
      if Index >= MAX_WAVE_BLOCKS then
        raise Exception.Create('波形の読み込み上限を超える長さの音源です。');
      if Index >= Length(FBlocks) then SetLength(FBlocks, Max(256, Length(FBlocks) * 2));
      FBlocks[Index].Minimum := 1;
      FBlocks[Index].Maximum := -1;
      FCount := Index + 1;
    end;
    for Channel := 0 to Format.nChannels - 1 do
    begin
      Value := ReadSample(Data + Frame * Format.nBlockAlign + Channel * BytesPerSample,
        Format.wBitsPerSample, Format.wFormatTag = 3);
      FBlocks[Index].Minimum := Min(FBlocks[Index].Minimum, Value);
      FBlocks[Index].Maximum := Max(FBlocks[Index].Maximum, Value);
    end;
    Inc(FFrames);
  end;
end;

procedure TEnvelopeBuilder.Finish(out Wave: TMusicStudioWaveform;
  out Info: TMusicStudioAudioInfo; const Format: TWaveFormatEx);
var
  I, J, Count, FirstBlock, LastBlock: Integer;
begin
  if FFrames = 0 then raise Exception.Create('音声サンプルがありません。');
  Info.Duration := FFrames / Format.nSamplesPerSec;
  if Info.Duration > 604800 then raise Exception.Create('音声の長さが上限604800秒を超えています。');
  Info.SampleRate := Format.nSamplesPerSec;
  Info.Channels := Format.nChannels;
  Count := Min(4096, FCount);
  SetLength(Wave, Count);
  for I := 0 to Count - 1 do
  begin
    FirstBlock := Int64(I) * FCount div Count;
    LastBlock := Int64(I + 1) * FCount div Count;
    Wave[I].Minimum := 1;
    Wave[I].Maximum := -1;
    for J := FirstBlock to LastBlock - 1 do
    begin
      Wave[I].Minimum := Min(Wave[I].Minimum, FBlocks[J].Minimum);
      Wave[I].Maximum := Max(Wave[I].Maximum, FBlocks[J].Maximum);
    end;
  end;
end;

procedure DecodeWav(Job: TMusicStudioWaveJob; Builder: TEnvelopeBuilder);
var
  Stream: TFileStream;
  Header: TRiffHeader;
  Chunk: TChunkHeader;
  Format: TWaveFormatEx;
  FormatBytes, Buffer: TBytes;
  Limit, NextChunk, DataPosition, DataSize, Remaining: Int64;
  ReadSize: Integer;
  HasFormat, HasData: Boolean;
  Subtype: TGUID;
begin
  Stream := TFileStream.Create(Job.FilePath, fmOpenRead or fmShareDenyWrite);
  try
    Stream.ReadBuffer(Header, SizeOf(Header));
    if (Header.Tag <> 'RIFF') or (Header.Kind <> 'WAVE') then
      raise Exception.Create('WAVのRIFF/WAVEヘッダーがありません。');
    Limit := Int64(Header.Size) + 8;
    if (Limit > Stream.Size) or (Limit < 12) then
      raise Exception.Create('WAVのファイルサイズ情報が壊れています。');
    HasFormat := False;
    HasData := False;
    DataPosition := 0;
    DataSize := 0;
    Format := Default(TWaveFormatEx);
    while Stream.Position + SizeOf(Chunk) <= Limit do
    begin
      if Job.Terminated then Exit;
      Stream.ReadBuffer(Chunk, SizeOf(Chunk));
      NextChunk := Stream.Position + Int64(Chunk.Size) + (Chunk.Size and 1);
      if NextChunk > Limit then raise Exception.Create('WAVのチャンクが途中で切れています。');
      if Chunk.Tag = 'fmt ' then
      begin
        if (Chunk.Size < 16) or (Chunk.Size > 65536) then
          raise Exception.Create('WAVの形式チャンクが壊れています。');
        SetLength(FormatBytes, Max(SizeOf(Format), Integer(Chunk.Size)));
        Stream.ReadBuffer(FormatBytes[0], Chunk.Size);
        Move(FormatBytes[0], Format, SizeOf(Format));
        if Format.wFormatTag = $FFFE then
        begin
          if Chunk.Size < 40 then raise Exception.Create('WAV拡張形式が不完全です。');
          Move(FormatBytes[24], Subtype, SizeOf(Subtype));
          if IsEqualGUID(Subtype, StringToGUID('{00000001-0000-0010-8000-00AA00389B71}')) then
            Format.wFormatTag := 1
          else if IsEqualGUID(Subtype, StringToGUID('{00000003-0000-0010-8000-00AA00389B71}')) then
            Format.wFormatTag := 3
          else raise Exception.Create('このWAV拡張形式には対応していません。');
        end;
        CheckFormat(Format);
        HasFormat := True;
      end
      else if (Chunk.Tag = 'data') and not HasData then
      begin
        HasData := True;
        DataPosition := Stream.Position;
        DataSize := Chunk.Size;
      end;
      Stream.Position := NextChunk;
    end;
    if not HasFormat or not HasData then
      raise Exception.Create('WAVの形式または音声データがありません。');
    if DataSize mod Format.nBlockAlign <> 0 then
      raise Exception.Create('WAVの音声サンプル終端が壊れています。');
    Stream.Position := DataPosition;
    SetLength(Buffer, (65536 div Format.nBlockAlign) * Format.nBlockAlign);
    Remaining := DataSize;
    while (Remaining > 0) and not Job.Terminated do
    begin
      ReadSize := Min(Int64(Length(Buffer)), Remaining);
      Stream.ReadBuffer(Buffer[0], ReadSize);
      Builder.Append(@Buffer[0], ReadSize, Format, Job);
      Dec(Remaining, ReadSize);
    end;
    if not Job.Terminated then Builder.Finish(Job.Waveform, Job.Info, Format);
  finally
    Stream.Free;
  end;
end;

procedure DecodeMp3(Job: TMusicStudioWaveJob; Builder: TEnvelopeBuilder);
var
  Reader: IWMSyncReader;
  Props: IWMOutputMediaProps;
  Sample: INSSBuffer;
  MediaBytes: TBytes;
  Media: PWMMediaType;
  Format: TWaveFormatEx;
  Size, Count, Output, Flags, SampleOutput, Bytes: LongWord;
  Stream, SampleStream: Word;
  SampleTime, Duration: Int64;
  Buffer: PByte;
  Kind: TGUID;
  HR: HRESULT;
  Found: Boolean;
begin
  OleCheck(CreateSyncReader(nil, 0, Reader));
  OleCheck(Reader.Open(PWideChar(Job.FilePath)));
  try
    OleCheck(Reader.GetOutputCount(Count));
    Found := False;
    Output := 0;
    while Output < Count do
    begin
      OleCheck(Reader.GetOutputProps(Output, Props));
      OleCheck(Props.GetType(Kind));
      if IsEqualGUID(Kind, WMMEDIATYPE_Audio) then begin Found := True; Break; end;
      Inc(Output);
    end;
    if not Found then raise Exception.Create('MP3に音声ストリームがありません。');
    Size := 0;
    OleCheck(Props.GetMediaType(nil, Size));
    if (Size < SizeOf(TWMMediaType)) or (Size > 1048576) then
      raise Exception.Create('MP3のデコード形式情報が壊れています。');
    SetLength(MediaBytes, Size);
    Media := PWMMediaType(@MediaBytes[0]);
    OleCheck(Props.GetMediaType(Media, Size));
    if not IsEqualGUID(Media.formattype, WMFORMAT_WaveFormatEx) or
      (Media.cbFormat < SizeOf(TWaveFormatEx)) or (Media.pbFormat = nil) then
      raise Exception.Create('MP3をPCM形式へ変換できません。');
    Move(Media.pbFormat^, Format, SizeOf(Format));
    CheckFormat(Format);
    OleCheck(Reader.GetStreamNumberForOutput(Output, Stream));
    OleCheck(Reader.SetReadStreamSamples(Stream, False));
    while not Job.Terminated do
    begin
      Sample := nil;
      HR := Reader.GetNextSample(Stream, Sample, SampleTime, Duration, Flags, SampleOutput, SampleStream);
      if HR = NS_E_NO_MORE_SAMPLES then Break;
      OleCheck(HR);
      if Sample = nil then raise Exception.Create('MP3の音声サンプルが取得できません。');
      OleCheck(Sample.GetBufferAndLength(Buffer, Bytes));
      if (Buffer = nil) or (Bytes > 1048576) then
        raise Exception.Create('MP3の音声サンプルが壊れています。');
      Builder.Append(Buffer, Bytes, Format, Job);
    end;
    if not Job.Terminated then Builder.Finish(Job.Waveform, Job.Info, Format);
  finally
    Sample := nil;
    Props := nil;
    Reader.Close;
    Reader := nil;
  end;
end;

constructor TMusicStudioWaveJob.Create(const Path: string; ID: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FilePath := Path;
  RequestID := ID;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TMusicStudioWaveJob.Destroy;
begin
  Terminate;
  WaitFor;
  FDone.Free;
  inherited;
end;

function TMusicStudioWaveJob.Done: Boolean;
begin
  // TThreadは開始前にTerminateされるとExecute自体を省略する。その場合も回収可能にする。
  Result := (FDone.WaitFor(0) = wrSignaled) or Finished;
end;

procedure TMusicStudioWaveJob.Decode;
var
  Builder: TEnvelopeBuilder;
  Ext: string;
begin
  if not TFile.Exists(FilePath) then raise Exception.Create('参照先の音源ファイルが見つかりません。');
  Ext := LowerCase(ExtractFileExt(FilePath));
  if (Ext <> '.wav') and (Ext <> '.mp3') then
    raise Exception.Create('WAVまたはMP3を選択してください。');
  Builder := TEnvelopeBuilder.Create;
  try
    if Ext = '.wav' then DecodeWav(Self, Builder) else DecodeMp3(Self, Builder);
  finally
    Builder.Free;
  end;
end;

procedure TMusicStudioWaveJob.Execute;
var
  Initialized: Boolean;
begin
  Initialized := Succeeded(CoInitializeEx(nil, COINIT_MULTITHREADED));
  try
    try
      if not Initialized then raise Exception.Create('音声デコーダを初期化できません。');
      Decode;
    except
      on E: Exception do begin
        ErrorText := E.Message; Waveform := nil; Info := Default(TMusicStudioAudioInfo);
      end;
    end;
  finally
    if Initialized then CoUninitialize;
    FDone.SetEvent;
  end;
end;

end.
