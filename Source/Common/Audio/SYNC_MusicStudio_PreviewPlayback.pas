unit SYNC_MusicStudio_PreviewPlayback;

// 編集用試聴。文書の値コピーを逐次デコード/合成し、waveOutの再生時計をUIへ返す。
// DLL映像コールバックとは独立。PCM全体を蓄積せず、終了時に自身の出力だけreset/closeする。
interface
uses System.Classes, System.SyncObjs;
type
  TMusicStudioPreviewClip = record
    FilePath, Name: string;
    StartSeconds, LengthSeconds, Volume: Double;
  end;
  TMusicStudioPreviewClips = TArray<TMusicStudioPreviewClip>;
  TMusicStudioPlaybackState = (psPreparing,psPlaying,psFinished,psFailed);
  TMusicStudioPlaybackSnapshot = record
    State: TMusicStudioPlaybackState;
    Position: Double;
    Peak: Single;
    SubmittedFrames: Int64;
    Message: string;
  end;
  TMusicStudioPlaybackJob = class(TThread)
  private
    FLock: TCriticalSection;
    FDone: TEvent;
    FClips: TMusicStudioPreviewClips;
    FStart, FEnd: Double;
    FSnapshot: TMusicStudioPlaybackSnapshot;
    procedure Publish(State: TMusicStudioPlaybackState; Position: Double; Peak: Single;
      Frames: Int64; const Message: string);
  protected
    procedure Execute; override;
  public
    // 呼出側はStartし、Terminate/WaitFor/Freeする。コールバックと文書参照は保持しない。
    constructor Create(const Clips: TMusicStudioPreviewClips; StartSeconds, EndSeconds: Double);
    destructor Destroy; override;
    function Snapshot: TMusicStudioPlaybackSnapshot;
    function Done: Boolean;
  end;
// 検証用の所有出力数。ホストや他アプリのデバイスへはアクセスしない。
function MusicStudioPreviewOutputCount: Integer;
implementation
uses System.SysUtils, System.Math, Winapi.Windows, Winapi.ActiveX, Winapi.MMSystem,
  Winapi.WMF9, System.Win.ComObj;
const SAMPLE_RATE=44100; BLOCK_FRAMES=1024; BUFFER_COUNT=4;
var ActiveOutputs: Integer;
type
  TPreviewVoice = class
  private
    FOwner: TThread;
    FReader: IWMSyncReader;
    FStream: Word;
    FSample: INSSBuffer;
    FData: PByte;
    FBytes: Cardinal;
    FFormat: TWaveFormatEx;
    FBufferStart: Int64;
    FEOF: Boolean;
    FWav: TFileStream;
    FWavBytes: TBytes;
    FDataEnd: Int64;
    procedure OpenWav(Start: Double);
    procedure CheckPCM;
    function Next: Boolean;
    function ValueAt(Frame: Int64; Channel: Integer): Single;
  public
    Clip: TMusicStudioPreviewClip;
    constructor Create(const Source: TMusicStudioPreviewClip; Start: Double; Owner: TThread);
    destructor Destroy; override;
    function SampleAt(Seconds: Double; Channel: Integer): Single;
  end;
  TOutputBlock = record
    Header: TWaveHdr;
    Samples: array[0..BLOCK_FRAMES*2-1] of SmallInt;
    Prepared, Submitted: Boolean;
  end;
  TThreadAccess = class(TThread);
{$WARN SYMBOL_PLATFORM OFF}
function CreatePreviewReader(Cert: IUnknown; Rights: LongWord; out Reader: IWMSyncReader): HRESULT; stdcall;
  external 'wmvcore.dll' name 'WMCreateSyncReader' delayed;
{$WARN SYMBOL_PLATFORM ON}
function MusicStudioPreviewOutputCount: Integer;
begin Result := InterlockedCompareExchange(ActiveOutputs,0,0); end;
procedure TPreviewVoice.CheckPCM;
begin
  if (FFormat.nChannels < 1) or (FFormat.nChannels > 32) or (FFormat.nSamplesPerSec < 1) or
    (FFormat.nSamplesPerSec > 768000) or (FFormat.nBlockAlign <> FFormat.nChannels*(FFormat.wBitsPerSample div 8)) or
    not (((FFormat.wFormatTag=1) and (FFormat.wBitsPerSample in [8,16,24,32])) or
      ((FFormat.wFormatTag=3) and (FFormat.wBitsPerSample=32))) then raise Exception.Create('非対応PCM形式です');
end;
procedure TPreviewVoice.OpenWav(Start: Double);
type
  TRiff = packed record Tag: array[0..3] of AnsiChar; Size: Cardinal; Kind: array[0..3] of AnsiChar; end;
  TChunk = packed record Tag: array[0..3] of AnsiChar; Size: Cardinal; end;
var Header: TRiff; Chunk: TChunk; Limit,NextChunk,DataPosition,DataSize,Frame: Int64;
  FormatBytes: TBytes; Subtype: TGUID; HasFormat,HasData: Boolean;
begin
  // 既存AudioWaveformのRIFF検証を再利用し、PCM本体はシーク位置から固定サイズで読む。
  FWav := TFileStream.Create(Clip.FilePath,fmOpenRead or fmShareDenyWrite);
  FWav.ReadBuffer(Header,SizeOf(Header));
  if (Header.Tag<>'RIFF') or (Header.Kind<>'WAVE') then raise Exception.Create('WAVヘッダーがありません');
  Limit := Int64(Header.Size)+8;
  if (Limit>FWav.Size) or (Limit<12) then raise Exception.Create('WAVサイズ情報が不正です');
  HasFormat := False; HasData := False; DataPosition := 0; DataSize := 0;
  FillChar(FFormat,SizeOf(FFormat),0);
  while FWav.Position+SizeOf(Chunk)<=Limit do begin
    if TThreadAccess(FOwner).Terminated then raise EAbort.Create('再生準備を中断しました');
    FWav.ReadBuffer(Chunk,SizeOf(Chunk)); NextChunk := FWav.Position+Int64(Chunk.Size)+(Chunk.Size and 1);
    if NextChunk>Limit then raise Exception.Create('WAVチャンクが途中で切れています');
    if Chunk.Tag='fmt ' then begin
      if (Chunk.Size<16) or (Chunk.Size>65536) then raise Exception.Create('WAV形式が不正です');
      SetLength(FormatBytes,Max(SizeOf(FFormat),Integer(Chunk.Size))); FWav.ReadBuffer(FormatBytes[0],Chunk.Size);
      Move(FormatBytes[0],FFormat,SizeOf(FFormat));
      if FFormat.wFormatTag=$FFFE then begin
        if Chunk.Size<40 then raise Exception.Create('WAV拡張形式が不完全です');
        Move(FormatBytes[24],Subtype,SizeOf(Subtype));
        if IsEqualGUID(Subtype,StringToGUID('{00000001-0000-0010-8000-00AA00389B71}')) then FFormat.wFormatTag := 1
        else if IsEqualGUID(Subtype,StringToGUID('{00000003-0000-0010-8000-00AA00389B71}')) then FFormat.wFormatTag := 3
        else raise Exception.Create('非対応WAV拡張形式です');
      end;
      CheckPCM; HasFormat := True;
    end else if (Chunk.Tag='data') and not HasData then begin
      HasData := True; DataPosition := FWav.Position; DataSize := Chunk.Size;
    end;
    FWav.Position := NextChunk;
  end;
  if not HasFormat or not HasData then raise Exception.Create('WAV形式/音声データがありません');
  if DataSize mod FFormat.nBlockAlign<>0 then raise Exception.Create('WAVサンプル終端が不正です');
  Frame := Min(DataSize div FFormat.nBlockAlign,Floor(Max(0.0,Start-Clip.StartSeconds)*FFormat.nSamplesPerSec));
  FDataEnd := DataPosition+DataSize; FWav.Position := DataPosition+Frame*FFormat.nBlockAlign;
  FBufferStart := Frame; SetLength(FWavBytes,(65536 div FFormat.nBlockAlign)*FFormat.nBlockAlign);
end;
constructor TPreviewVoice.Create(const Source: TMusicStudioPreviewClip; Start: Double; Owner: TThread);
var Count,Output,Size: Cardinal; Props: IWMOutputMediaProps; Kind: TGUID; Bytes: TBytes; Media: PWMMediaType;
begin
  inherited Create; Clip := Source; FOwner := Owner;
  if not FileExists(Clip.FilePath) then raise Exception.Create('音源参照がありません');
  if not SameText(ExtractFileExt(Clip.FilePath),'.wav') and not SameText(ExtractFileExt(Clip.FilePath),'.mp3') then
    raise Exception.Create('試聴はWAV/MP3のみです');
  if SameText(ExtractFileExt(Clip.FilePath),'.wav') then begin OpenWav(Start); Exit; end;
  OleCheck(CreatePreviewReader(nil,0,FReader)); OleCheck(FReader.Open(PWideChar(Clip.FilePath)));
  OleCheck(FReader.GetOutputCount(Count)); Output := 0;
  while Output < Count do begin
    OleCheck(FReader.GetOutputProps(Output,Props)); OleCheck(Props.GetType(Kind));
    if IsEqualGUID(Kind,WMMEDIATYPE_Audio) then Break; Inc(Output);
  end;
  if Output = Count then raise Exception.Create('音声ストリームがありません');
  Size := 0; OleCheck(Props.GetMediaType(nil,Size));
  if (Size < SizeOf(TWMMediaType)) or (Size > 1048576) then raise Exception.Create('音声形式情報が不正です');
  SetLength(Bytes,Size); Media := PWMMediaType(@Bytes[0]); OleCheck(Props.GetMediaType(Media,Size));
  if not IsEqualGUID(Media.formattype,WMFORMAT_WaveFormatEx) or (Media.pbFormat=nil) or
    (Media.cbFormat < SizeOf(FFormat)) then raise Exception.Create('PCMへ変換できません');
  Move(Media.pbFormat^,FFormat,SizeOf(FFormat));
  CheckPCM;
  OleCheck(FReader.GetStreamNumberForOutput(Output,FStream)); OleCheck(FReader.SetReadStreamSamples(FStream,False));
  OleCheck(FReader.SetRange(Round(Max(0.0,Start-Clip.StartSeconds)*10000000),0));
end;
destructor TPreviewVoice.Destroy;
begin FWav.Free; FSample := nil; if Assigned(FReader) then FReader.Close; FReader := nil; inherited; end;
function TPreviewVoice.Next: Boolean;
var Time,Duration: Int64; Flags,Output: Cardinal; Stream: Word; HR: HRESULT;
begin
  if Assigned(FWav) then begin
    if FWav.Position>=FDataEnd then begin FEOF := True; Exit(False); end;
    Inc(FBufferStart,FBytes div FFormat.nBlockAlign);
    FBytes := Min(Int64(Length(FWavBytes)),FDataEnd-FWav.Position); FWav.ReadBuffer(FWavBytes[0],FBytes);
    FData := @FWavBytes[0]; Exit(True);
  end;
  FSample := nil; FData := nil; FBytes := 0;
  HR := FReader.GetNextSample(FStream,FSample,Time,Duration,Flags,Output,Stream);
  if HR=NS_E_NO_MORE_SAMPLES then begin FEOF := True; Exit(False); end; OleCheck(HR);
  if FSample=nil then raise Exception.Create('PCMサンプルがありません');
  OleCheck(FSample.GetBufferAndLength(FData,FBytes));
  if (FData=nil) or (FBytes=0) or (FBytes>1048576) or (FBytes mod FFormat.nBlockAlign <> 0) then
    raise Exception.Create('PCMサンプルが壊れています');
  FBufferStart := Round(Time*FFormat.nSamplesPerSec/10000000); Result := True;
end;
function TPreviewVoice.ValueAt(Frame: Int64; Channel: Integer): Single;
var Data: PByte; N: Integer;
begin
  Result := 0;
  while not FEOF and ((FData=nil) or (Frame >= FBufferStart+FBytes div FFormat.nBlockAlign)) do if not Next then Exit;
  if FEOF or (Frame < FBufferStart) then Exit;
  Channel := Min(Channel,FFormat.nChannels-1);
  Data := FData+(Frame-FBufferStart)*FFormat.nBlockAlign+Channel*(FFormat.wBitsPerSample div 8);
  if FFormat.wFormatTag=3 then Result := PSingle(Data)^ else case FFormat.wBitsPerSample of
    8: Result := (Data^ - 128)/128;
    16: Result := PSmallInt(Data)^/32768;
    24: begin N := Data[0] or (Integer(Data[1]) shl 8) or (Integer(Data[2]) shl 16);
      if N and $800000 <> 0 then N := N-$1000000; Result := N/8388608; end;
    32: Result := PInteger(Data)^/2147483648.0;
  end;
  if IsNan(Result) or IsInfinite(Result) then raise Exception.Create('PCM値が不正です');
end;
function TPreviewVoice.SampleAt(Seconds: Double; Channel: Integer): Single;
begin
  Result := 0;
  if (Seconds < Clip.StartSeconds) or (Seconds >= Clip.StartSeconds+Clip.LengthSeconds) then Exit;
  Result := ValueAt(Floor((Seconds-Clip.StartSeconds)*FFormat.nSamplesPerSec),Channel)*Clip.Volume;
end;
constructor TMusicStudioPlaybackJob.Create(const Clips: TMusicStudioPreviewClips; StartSeconds,EndSeconds: Double);
begin
  inherited Create(True); FreeOnTerminate := False; FLock := TCriticalSection.Create;
  FDone := TEvent.Create(nil,True,False,''); FClips := Copy(Clips);
  FStart := Max(0.0,StartSeconds); FEnd := Max(FStart,EndSeconds); FSnapshot.Position := FStart;
end;
destructor TMusicStudioPlaybackJob.Destroy;
begin Terminate; WaitFor; FDone.Free; FLock.Free; inherited; end;
procedure TMusicStudioPlaybackJob.Publish(State: TMusicStudioPlaybackState; Position: Double; Peak: Single;
  Frames: Int64; const Message: string);
begin
  FLock.Enter; try FSnapshot.State := State; FSnapshot.Position := Position;
    FSnapshot.Peak := Peak; FSnapshot.SubmittedFrames := Frames; FSnapshot.Message := Message;
  finally FLock.Leave; end;
end;
function TMusicStudioPlaybackJob.Snapshot: TMusicStudioPlaybackSnapshot;
begin FLock.Enter; try Result := FSnapshot; finally FLock.Leave; end; end;
function TMusicStudioPlaybackJob.Done: Boolean;
begin Result := FDone.WaitFor(0)=wrSignaled; end;
procedure TMusicStudioPlaybackJob.Execute;
var Device: HWAVEOUT; Format: TWaveFormatEx; Blocks: array[0..BUFFER_COUNT-1] of TOutputBlock;
  Voices: TArray<TPreviewVoice>; Clip: TMusicStudioPreviewClip; I,J,C,N,Frames: Integer;
  Submitted,TotalFrames,NativeTicks,Delta: Int64; Seconds,Position,Value,TickRate: Double;
  Peak: Single; Pending,Initialized,OutputOpened: Boolean;
  Message: string; Time: TMMTime; LastTick,CurrentTick: Cardinal;
  procedure MMCheck(Code: MMRESULT);
  begin if Code <> MMSYSERR_NOERROR then raise Exception.CreateFmt('音声出力エラー %d',[Code]); end;
begin
  Device := 0; OutputOpened := False; FillChar(Blocks,SizeOf(Blocks),0); Submitted := 0; Position := FStart;
  NativeTicks := 0; LastTick := 0;
  Initialized := Succeeded(CoInitializeEx(nil,COINIT_MULTITHREADED));
  try
    try
      if not Initialized then raise Exception.Create('音声COMを初期化できません');
      for Clip in FClips do begin
        if Terminated then Exit;
        if Clip.StartSeconds+Clip.LengthSeconds <= FStart then Continue;
        try
          N := Length(Voices); SetLength(Voices,N+1); Voices[N] := TPreviewVoice.Create(Clip,FStart,Self);
        except on E: Exception do Message := Copy(Message+Clip.Name+': '+E.Message+' / ',1,1024); end;
      end;
      if Length(FClips)=0 then Message := '音声配置なし。歌唱MIDIの歌声生成は未実装。';
      if Terminated then Exit;
      FillChar(Format,SizeOf(Format),0); Format.wFormatTag := WAVE_FORMAT_PCM; Format.nChannels := 2;
      Format.nSamplesPerSec := SAMPLE_RATE; Format.wBitsPerSample := 16; Format.nBlockAlign := 4;
      Format.nAvgBytesPerSec := SAMPLE_RATE*4;
      MMCheck(waveOutOpen(@Device,WAVE_MAPPER,@Format,0,0,CALLBACK_NULL)); OutputOpened := True;
      InterlockedIncrement(ActiveOutputs);
      TotalFrames := Round((FEnd-FStart)*SAMPLE_RATE);
      Peak := 0;
      repeat
        Pending := False;
        for I := 0 to BUFFER_COUNT-1 do begin
          if Blocks[I].Submitted then begin
            if Blocks[I].Header.dwFlags and WHDR_DONE=0 then begin Pending := True; Continue; end;
            MMCheck(waveOutUnprepareHeader(Device,@Blocks[I].Header,SizeOf(TWaveHdr)));
            Blocks[I].Prepared := False; Blocks[I].Submitted := False;
          end;
          if Terminated or (Submitted >= TotalFrames) then Continue;
          Frames := Min(BLOCK_FRAMES,TotalFrames-Submitted);
          Peak := 0;
          for J := 0 to Frames-1 do begin
            if Terminated then Break;
            Seconds := FStart+(Submitted+J)/SAMPLE_RATE;
            for C := 0 to 1 do begin
              Value := 0;
              for N := 0 to High(Voices) do if Assigned(Voices[N]) then
                try Value := Value+Voices[N].SampleAt(Seconds,C);
                except on E: Exception do begin Message := Copy(Message+E.Message+' / ',1,1024); FreeAndNil(Voices[N]); end; end;
              Value := EnsureRange(Value,-1.0,1.0); Peak := Max(Peak,Abs(Value));
              Blocks[I].Samples[J*2+C] := Round(Value*32767);
            end;
          end;
          if Terminated then Break;
          FillChar(Blocks[I].Header,SizeOf(TWaveHdr),0);
          Blocks[I].Header.lpData := PAnsiChar(@Blocks[I].Samples[0]); Blocks[I].Header.dwBufferLength := Frames*4;
          MMCheck(waveOutPrepareHeader(Device,@Blocks[I].Header,SizeOf(TWaveHdr))); Blocks[I].Prepared := True;
          MMCheck(waveOutWrite(Device,@Blocks[I].Header,SizeOf(TWaveHdr))); Blocks[I].Submitted := True;
          Inc(Submitted,Frames); Pending := True;
        end;
        FillChar(Time,SizeOf(Time),0); Time.wType := TIME_SAMPLES;
        MMCheck(waveOutGetPosition(Device,@Time,SizeOf(Time)));
        TickRate := SAMPLE_RATE;
        if Time.wType=TIME_SAMPLES then CurrentTick := Time.sample
        else if Time.wType=TIME_BYTES then begin CurrentTick := Time.cb; TickRate := SAMPLE_RATE*4; end
        else if Time.wType=TIME_MS then begin CurrentTick := Time.ms; TickRate := 1000; end
        else raise Exception.Create('音声出力の再生時計が非対応です');
        Delta := Int64(CurrentTick)-LastTick; if Delta<0 then Inc(Delta,Int64(4294967296));
        Inc(NativeTicks,Delta); LastTick := CurrentTick; Position := FStart+NativeTicks/TickRate;
        Publish(psPlaying,Min(FEnd,Position),Peak,Submitted,Message);
        if Pending and not Terminated then Sleep(2);
      until Terminated or not Pending;
      if not Terminated then Publish(psFinished,FEnd,0,Submitted,Message);
    except on E: Exception do Publish(psFailed,Position,0,Submitted,E.Message); end;
  finally
    if OutputOpened then begin
      waveOutReset(Device);
      for I := 0 to BUFFER_COUNT-1 do if Blocks[I].Prepared then waveOutUnprepareHeader(Device,@Blocks[I].Header,SizeOf(TWaveHdr));
      waveOutClose(Device);
      InterlockedDecrement(ActiveOutputs);
    end;
    for I := 0 to High(Voices) do Voices[I].Free;
    if Initialized then CoUninitialize; FDone.SetEvent;
  end;
end;
end.
