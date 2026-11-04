unit SYNC_MusicStudio_SingingFormats;
// SYNC_LyricsのSongReader各形式を参考に、歌唱用の音符/歌詞/秒へ正規化する。
// UI/音声処理/原本保存は行わず、ZIPもメモリー内だけで読み、workerの取消を尊重する。
interface
uses System.Classes, SYNC_MusicStudio_SingingData;
const
  MUSIC_STUDIO_SONG_FILTER = '歌唱データ|*.mid;*.midi;*.kar;*.ust;*.vsqx;*.musicxml;*.xml;*.mxl;*.mscx;*.mscz|MIDI / KAR|*.mid;*.midi;*.kar|UTAU UST|*.ust|VOCALOID VSQX|*.vsqx|MusicXML|*.musicxml;*.xml;*.mxl|MuseScore|*.mscx;*.mscz|すべてのファイル|*.*';
function MusicStudioStructuredSong(const Ext: string): Boolean;
// 呼出側が例外をstatusへ変換する。部分結果を公開せず、共有ライブラリにも書き込まない。
function LoadMusicStudioStructuredSong(const Path: string; Cancel: TThread): TMusicStudioSingingSource;
implementation
uses System.SysUtils, System.Math, System.IOUtils, System.Variants, System.Zip,
  System.Generics.Collections, System.Generics.Defaults, Winapi.ActiveX, Winapi.Windows,
  Xml.XMLDoc, Xml.XMLIntf, Xml.Win.msxmldom, SYNC_MusicStudio_Vowels;
type
  TThreadAccess = class(TThread);
  TRawSongNote = record Beat,EndBeat: Double; Track,Key: Integer; Lyric: string; end;
  TSongTempo = record Beat,BPM,Seconds: Double; Order: Integer; end;
  TSongParser = class
    Notes: TList<TRawSongNote>;
    Tempos: TList<TSongTempo>;
    Tracks: TList<TMusicStudioSingingTrack>;
    Cancel: TThread;
    constructor Create(ACancel: TThread);
    destructor Destroy; override;
    procedure Check;
    function Track(ID: Integer; const Name: string): Integer;
    procedure Tempo(Beat,BPM: Double);
    procedure Note(Track,Key: Integer; Beat,Duration: Double; const Lyric: string);
    procedure UST(const Text: string);
    procedure VSQX(Root: IXMLNode);
    procedure MusicXML(Root: IXMLNode);
    procedure MuseScore(Root: IXMLNode);
    function Finish: TMusicStudioSingingSource;
  end;
const MAX_SONG_BYTES = 32*1024*1024;
function MusicStudioStructuredSong(const Ext: string): Boolean;
begin Result := (Ext='.ust') or (Ext='.vsqx') or (Ext='.musicxml') or (Ext='.xml') or
  (Ext='.mxl') or (Ext='.mscx') or (Ext='.mscz'); end;
function Child(N: IXMLNode; const Name: string): IXMLNode;
var I: Integer;
begin Result := nil; if N=nil then Exit;
  for I := 0 to N.ChildNodes.Count-1 do if SameText(N.ChildNodes[I].LocalName,Name) then Exit(N.ChildNodes[I]); end;
function Txt(N: IXMLNode; const Name,Default: string): string;
begin N := Child(N,Name); if N=nil then Result := Default else Result := N.Text; end;
function Num(N: IXMLNode; const Name: string; Default: Double): Double;
begin if not TryStrToFloat(Txt(N,Name,''),Result,TFormatSettings.Invariant) then Result := Default; end;
function Attr(N: IXMLNode; const Name: string): string;
begin Result := ''; if (N<>nil) and N.HasAttribute(Name) then Result := VarToStr(N.Attributes[Name]); end;
function Decode(const Data: TBytes): string;
var E: TEncoding;
begin
  if (Length(Data)>=2) and (Data[0]=$FF) and (Data[1]=$FE) then Exit(TEncoding.Unicode.GetString(Data,2,Length(Data)-2));
  if (Length(Data)>=2) and (Data[0]=$FE) and (Data[1]=$FF) then Exit(TEncoding.BigEndianUnicode.GetString(Data,2,Length(Data)-2));
  if (Length(Data)>0) and (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,PAnsiChar(@Data[0]),Length(Data),nil,0)=0) then begin
    E := TEncoding.GetEncoding(932); try Result := E.GetString(Data); finally E.Free; end;
  end else Result := TEncoding.UTF8.GetString(Data);
  if (Result<>'') and (Result[1]=#$FEFF) then Delete(Result,1,1);
end;
function XML(const Text: string): IXMLDocument;
var S: string; A,B,Depth: Integer; Quote: Char;
begin
  S := Text; A := Pos('<!DOCTYPE',UpperCase(S));
  // 一般的なMusicXMLの外部DTDは表示読込に不要。内部subsetも含めて除去する。
  if A>0 then begin B := A+9; Depth := 0; Quote := #0;
    while B<=Length(S) do begin
      if Quote<>#0 then begin if S[B]=Quote then Quote := #0; end
      else if CharInSet(S[B],['"',#39]) then Quote := S[B]
      else if S[B]='[' then Inc(Depth) else if S[B]=']' then Dec(Depth)
      else if (S[B]='>') and (Depth=0) then Break;
      Inc(B);
    end;
    if B>Length(S) then raise Exception.Create('XMLのDOCTYPEが閉じていません。'); Delete(S,A,B-A+1);
  end;
  Result := NewXMLDocument; Result.ParseOptions := []; Result.LoadFromXML(S); Result.Active := True;
  if Result.DocumentElement=nil then raise Exception.Create('XMLのルートがありません。');
end;
function ReadSongText(const Path: string): string;
var Z: TZipFile; Data: TBytes; I,Pick,Candidates: Integer; Ext,Target: string; Doc: IXMLDocument; N: IXMLNode;
  procedure ReadEntry(Index: Integer);
  begin
    if (Z.FileInfo[Index].UncompressedSize64>MAX_SONG_BYTES) then raise Exception.Create('展開後の楽譜が32MiBを超えています。');
    Z.Read(Index,Data);
  end;
begin
  if TFile.GetSize(Path)>MAX_SONG_BYTES then raise Exception.Create('歌唱ファイルが32MiBを超えています。');
  Ext := LowerCase(ExtractFileExt(Path));
  if (Ext<>'.mxl') and (Ext<>'.mscz') then Exit(Decode(TFile.ReadAllBytes(Path)));
  Z := TZipFile.Create;
  try
    Z.Open(Path,zmRead); if Z.FileCount>4096 then raise Exception.Create('圧縮楽譜の項目数が多すぎます。'); Target := '';
    I := Z.IndexOf('META-INF/container.xml');
    if I>=0 then begin ReadEntry(I); Doc := XML(Decode(Data)); N := Child(Child(Doc.DocumentElement,'rootfiles'),'rootfile'); Target := Attr(N,'full-path'); Doc := nil; end;
    Pick := -1; Candidates := 0;
    for I := 0 to Z.FileCount-1 do begin
      if Target<>'' then begin if Z.FileNames[I]=Target then begin Pick := I; Break; end; end
      else if not LowerCase(Z.FileNames[I]).StartsWith('meta-inf/') then begin
        Ext := LowerCase(ExtractFileExt(Z.FileNames[I]));
        if ((SameText(ExtractFileExt(Path),'.mscz')) and (Ext='.mscx')) or
          ((SameText(ExtractFileExt(Path),'.mxl')) and ((Ext='.xml') or (Ext='.musicxml'))) then begin Inc(Candidates); Pick := I; end;
      end;
    end;
    if (Pick<0) or ((Target='') and (Candidates<>1)) then raise Exception.Create('圧縮ファイル内の主楽譜を特定できません。');
    ReadEntry(Pick); Result := Decode(Data);
  finally Z.Free; end;
end;
constructor TSongParser.Create(ACancel: TThread);
begin inherited Create; Cancel := ACancel; Notes := TList<TRawSongNote>.Create;
  Tempos := TList<TSongTempo>.Create; Tracks := TList<TMusicStudioSingingTrack>.Create; Tempo(0,120); end;
destructor TSongParser.Destroy;
begin Tracks.Free; Tempos.Free; Notes.Free; inherited; end;
procedure TSongParser.Check;
begin if Assigned(Cancel) and TThreadAccess(Cancel).Terminated then raise EAbort.Create('取消'); end;
function TSongParser.Track(ID: Integer; const Name: string): Integer;
var I: Integer; T: TMusicStudioSingingTrack;
begin
  Check; if (ID<0) or (ID>65535) then raise Exception.Create('トラック番号が不正です。');
  for I := 0 to Tracks.Count-1 do if Tracks[I].Index=ID then Exit(ID);
  if Tracks.Count>=1024 then raise Exception.Create('トラック数が多すぎます。');
  T := Default(TMusicStudioSingingTrack); T.Index := ID; T.Name := Name; Tracks.Add(T); Result := ID;
end;
procedure TSongParser.Tempo(Beat,BPM: Double);
var T: TSongTempo;
begin
  Check; if IsNan(Beat) or IsInfinite(Beat) or IsNan(BPM) or IsInfinite(BPM) or (Beat<0) or (BPM<=0) or (BPM>10000) then raise Exception.Create('テンポが不正です。');
  if Tempos.Count>=100000 then raise Exception.Create('テンポ点が多すぎます。');
  T := Default(TSongTempo); T.Beat := Beat; T.BPM := BPM; T.Order := Tempos.Count; Tempos.Add(T);
end;
procedure TSongParser.Note(Track,Key: Integer; Beat,Duration: Double; const Lyric: string);
var N: TRawSongNote;
begin
  Check; if IsNan(Beat) or IsInfinite(Beat) or IsNan(Duration) or IsInfinite(Duration) or (Beat<0) or (Duration<=0) or (Key<0) or (Key>127) then raise Exception.Create('音符の位置・長さ・音高が不正です。');
  if (Notes.Count>=1000000) or (Length(Lyric)>4096) then raise Exception.Create('歌唱データが大きすぎます。');
  N.Beat := Beat; N.EndBeat := Beat+Duration; N.Track := Track; N.Key := Key; N.Lyric := Lyric; Notes.Add(N);
end;
procedure TSongParser.UST(const Text: string);
var Lines: TStringList; Line,Section,K,V,Lyric: string; I,P,Len,Pitch: Integer; Beat,BPM: Double; Active,SawSection: Boolean;
  procedure Commit;
  begin
    if not Active then Exit;
    if Len<=0 then raise Exception.Create('USTのLengthが不正です。');
    if BPM>0 then Tempo(Beat,BPM);
    if not SameText(Trim(Lyric),'R') and (Trim(Lyric)<>'') then Note(0,Pitch,Beat,Len/480,Lyric);
    Beat := Beat+Len/480; Active := False;
  end;
begin
  Track(0,'UST'); Beat := 0; Active := False; SawSection := False; Len := 0; Pitch := 60; BPM := 0; Lyric := ''; Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count-1 do begin
      Check; Line := Trim(Lines[I]); if Line='' then Continue;
      if Line.StartsWith('[#') and Line.EndsWith(']') then begin
        Commit; Section := Copy(Line,3,Length(Line)-3); Active := TryStrToInt(Section,P); SawSection := True;
        Len := 0; Pitch := 60; BPM := 0; Lyric := ''; Continue;
      end;
      P := Pos('=',Line); if P=0 then Continue; K := Copy(Line,1,P-1); V := Copy(Line,P+1,MaxInt);
      if Active then begin
        if SameText(K,'Length') then Len := StrToInt(V) else if SameText(K,'NoteNum') then Pitch := StrToInt(V)
        else if SameText(K,'Lyric') then Lyric := V else if SameText(K,'Tempo') then BPM := StrToFloat(V,TFormatSettings.Invariant);
      end else if SameText(Section,'SETTING') and SameText(K,'Tempo') then Tempo(0,StrToFloat(V,TFormatSettings.Invariant));
    end; Commit; if not SawSection then raise Exception.Create('USTのセクションがありません。');
  finally Lines.Free; end;
end;
procedure TSongParser.VSQX(Root: IXMLNode);
var Master,TNode,PNode,N: IXMLNode; V4: Boolean; I,J,K,TID: Integer; Res,Pre,Start,Duration,Offset,BPM: Double; TimeTag,ValueTag,PartTag,NoteTag,DurTag,KeyTag,LyricTag,NameTag: string;
begin
  V4 := SameText(Root.LocalName,'vsq4');
  if not V4 and not SameText(Root.LocalName,'vsq3') then raise Exception.Create('VSQX3/4のルートがありません。');
  if V4 then begin TimeTag := 't'; ValueTag := 'v'; PartTag := 'vsPart'; NoteTag := 't'; DurTag := 'dur'; KeyTag := 'n'; LyricTag := 'y'; NameTag := 'name'; end
  else begin TimeTag := 'posTick'; ValueTag := 'bpm'; PartTag := 'musicalPart'; NoteTag := 'posTick'; DurTag := 'durTick'; KeyTag := 'noteNum'; LyricTag := 'lyric'; NameTag := 'trackName'; end;
  Master := Child(Root,'masterTrack'); Res := Num(Master,'resolution',480); if Res<=0 then raise Exception.Create('VSQXのresolutionが不正です。');
  N := Child(Master,'timeSig'); Pre := Num(Master,'preMeasure',0)*Num(N,'nu',Num(N,'nume',4))*4/Max(1,Num(N,'de',Num(N,'denomi',4)));
  if Master<>nil then for I := 0 to Master.ChildNodes.Count-1 do begin
    N := Master.ChildNodes[I]; if not SameText(N.LocalName,'tempo') then Continue;
    BPM := Num(N,ValueTag,12000)/100; Tempo(Max(0,Num(N,TimeTag,0)/Res-Pre),BPM);
  end;
  for I := 0 to Root.ChildNodes.Count-1 do begin
    TNode := Root.ChildNodes[I]; if not SameText(TNode.LocalName,'vsTrack') then Continue;
    TID := Track(Round(Num(TNode,'tNo',Num(TNode,'vsTrackNo',Tracks.Count))),Txt(TNode,NameTag,''));
    for J := 0 to TNode.ChildNodes.Count-1 do begin
      PNode := TNode.ChildNodes[J]; if not SameText(PNode.LocalName,PartTag) then Continue;
      Offset := Num(PNode,TimeTag,0)/Res-Pre;
      for K := 0 to PNode.ChildNodes.Count-1 do begin
        Check; N := PNode.ChildNodes[K]; if not SameText(N.LocalName,'note') then Continue;
        Start := Offset+Num(N,NoteTag,0)/Res; Duration := Num(N,DurTag,0)/Res;
        if Start+Duration<=0 then Continue;
        if Start<0 then begin Duration := Duration+Start; Start := 0; end;
        Note(TID,Round(Num(N,KeyTag,60)),Start,Duration,Txt(N,LyricTag,''));
      end;
    end;
  end;
end;
function Pitch(N: IXMLNode): Integer;
var Step: string;
begin
  Step := Txt(N,'step','C');
  if Step='C' then Result := 0 else if Step='D' then Result := 2 else if Step='E' then Result := 4
  else if Step='F' then Result := 5 else if Step='G' then Result := 7 else if Step='A' then Result := 9 else Result := 11;
  Result := Result+Round(Num(N,'alter',0))+12*(Round(Num(N,'octave',4))+1);
end;
function Lyrics(N: IXMLNode; const Name: string): string;
var L: IXMLNode; I: Integer;
begin
  Result := ''; L := Child(N,Name); if L=nil then Exit;
  for I := 0 to L.ChildNodes.Count-1 do if SameText(L.ChildNodes[I].LocalName,'text') then Result := Result+L.ChildNodes[I].Text;
end;
procedure TSongParser.MusicXML(Root: IXMLNode);
var Part,Measure,N,A,S: IXMLNode; I,J,K,L,TID,Key,Index: Integer;
  Beat,HighBeat,MeasureStart,Previous,Divisions,Duration,Start,BPM: Double;
  Ties: TDictionary<string,Integer>; TieKey,Lyric,Name: string; HasStart,HasStop: Boolean; Raw: TRawSongNote;
begin
  if not SameText(Root.LocalName,'score-partwise') then raise Exception.Create('score-partwise形式のMusicXMLを指定してください。');
  Ties := TDictionary<string,Integer>.Create;
  try
    for I := 0 to Root.ChildNodes.Count-1 do begin
      Part := Root.ChildNodes[I]; if not SameText(Part.LocalName,'part') then Continue;
      Name := Attr(Part,'id'); A := Child(Root,'part-list');
      if A<>nil then for J := 0 to A.ChildNodes.Count-1 do if Attr(A.ChildNodes[J],'id')=Name then begin Name := Txt(A.ChildNodes[J],'part-name',Name); Break; end;
      TID := Track(Tracks.Count,Name); Beat := 0; Divisions := 1; Previous := 0; Ties.Clear;
      for J := 0 to Part.ChildNodes.Count-1 do begin
        Measure := Part.ChildNodes[J]; if not SameText(Measure.LocalName,'measure') then Continue;
        MeasureStart := Beat; HighBeat := Beat;
        for K := 0 to Measure.ChildNodes.Count-1 do begin
          Check; N := Measure.ChildNodes[K];
          if SameText(N.LocalName,'attributes') then begin Divisions := Num(N,'divisions',Divisions); if Divisions<=0 then raise Exception.Create('MusicXMLのdivisionsが不正です。'); end
          else if SameText(N.LocalName,'backup') then Beat := Max(MeasureStart,Beat-Num(N,'duration',0)/Divisions)
          else if SameText(N.LocalName,'forward') then Beat := Beat+Num(N,'duration',0)/Divisions
          else if SameText(N.LocalName,'direction') then begin
            S := Child(N,'sound'); BPM := StrToFloatDef(Attr(S,'tempo'),0,TFormatSettings.Invariant);
            if BPM=0 then begin A := Child(Child(N,'direction-type'),'metronome'); BPM := Num(A,'per-minute',0);
              Name := Txt(A,'beat-unit','quarter'); if Name='half' then BPM := BPM*2 else if Name='eighth' then BPM := BPM/2;
              if Child(A,'beat-unit-dot')<>nil then BPM := BPM*1.5;
            end;
            if BPM>0 then Tempo(Beat+Num(N,'offset',0)/Divisions,BPM);
          end else if SameText(N.LocalName,'note') then begin
            Duration := Num(N,'duration',0)/Divisions; if Duration<=0 then Continue;
            if Child(N,'chord')<>nil then Start := Previous else begin Start := Beat; Previous := Beat; Beat := Beat+Duration; end;
            HighBeat := Max(HighBeat,Start+Duration); if Child(N,'rest')<>nil then Continue;
            A := Child(N,'pitch'); if A=nil then Continue; Key := Pitch(A); Lyric := Lyrics(N,'lyric'); HasStart := False; HasStop := False;
            for L := 0 to N.ChildNodes.Count-1 do if SameText(N.ChildNodes[L].LocalName,'tie') then begin
              if Attr(N.ChildNodes[L],'type')='start' then HasStart := True;
              if Attr(N.ChildNodes[L],'type')='stop' then HasStop := True;
            end;
            TieKey := Txt(N,'voice','1')+':'+IntToStr(Key);
            if HasStop and Ties.TryGetValue(TieKey,Index) then begin
              Raw := Notes[Index]; Raw.EndBeat := Start+Duration; Notes[Index] := Raw;
              if not HasStart then Ties.Remove(TieKey);
            end else begin Note(TID,Key,Start,Duration,Lyric); if HasStart then Ties.AddOrSetValue(TieKey,Notes.Count-1); end;
          end;
          HighBeat := Max(HighBeat,Beat);
        end; Beat := HighBeat;
      end;
    end;
  finally Ties.Free; end;
end;
function DurationBeats(N: IXMLNode): Double;
var Kind,S: string; Dots,I,P: Integer;
begin
  Kind := Txt(N,'durationType','quarter');
  if Kind='long' then Result := 16 else if Kind='breve' then Result := 8 else if Kind='whole' then Result := 4
  else if Kind='half' then Result := 2 else if Kind='quarter' then Result := 1 else if Kind='eighth' then Result := 0.5
  else if Kind='16th' then Result := 0.25 else if Kind='32nd' then Result := 0.125 else if Kind='64th' then Result := 0.0625
  else if Kind='measure' then begin
    S := Txt(N,'duration','1/1'); P := Pos('/',S); if P=0 then Result := 4 else Result := StrToFloat(Copy(S,1,P-1),TFormatSettings.Invariant)*4/StrToFloat(Copy(S,P+1,MaxInt),TFormatSettings.Invariant);
  end else raise Exception.Create('MuseScoreの音符長 '+Kind+' は未対応です。');
  Dots := Round(Num(N,'dots',0)); if (Dots<0) or (Dots>4) then raise Exception.Create('付点数が不正です。');
  S := FloatToStr(Result,TFormatSettings.Invariant); // durationは下の付点計算でも同じ基準を使用。
  for I := 1 to Dots do Result := Result+StrToFloat(S,TFormatSettings.Invariant)/Power(2,I);
end;
procedure TSongParser.MuseScore(Root: IXMLNode);
var Score,Staff,Measure,Voice,N,A: IXMLNode; I,J,K,L,M,TID: Integer; Beat,HighBeat,MeasureStart,Duration: Double;
begin
  if not SameText(Root.LocalName,'museScore') then raise Exception.Create('MuseScoreのルートがありません。');
  Score := Child(Root,'Score'); if Score=nil then raise Exception.Create('MuseScoreのScoreがありません。');
  for I := 0 to Score.ChildNodes.Count-1 do begin
    Staff := Score.ChildNodes[I]; if not SameText(Staff.LocalName,'Staff') then Continue;
    TID := Track(Tracks.Count,'Staff '+Attr(Staff,'id')); Beat := 0;
    for J := 0 to Staff.ChildNodes.Count-1 do begin
      Measure := Staff.ChildNodes[J]; if not SameText(Measure.LocalName,'Measure') then Continue;
      MeasureStart := Beat; HighBeat := Beat;
      for K := 0 to Measure.ChildNodes.Count-1 do begin
        Voice := Measure.ChildNodes[K]; if not SameText(Voice.LocalName,'voice') then Continue; Beat := MeasureStart;
        for L := 0 to Voice.ChildNodes.Count-1 do begin
          Check; N := Voice.ChildNodes[L];
          if SameText(N.LocalName,'Tempo') then Tempo(Beat,Num(N,'tempo',2)*60)
          else if SameText(N.LocalName,'tick') then Beat := StrToFloat(N.Text,TFormatSettings.Invariant)/480
          else if SameText(N.LocalName,'Rest') or SameText(N.LocalName,'Chord') then begin
            Duration := DurationBeats(N);
            if SameText(N.LocalName,'Chord') then for M := 0 to N.ChildNodes.Count-1 do begin
              A := N.ChildNodes[M]; if SameText(A.LocalName,'Note') then Note(TID,Round(Num(A,'pitch',60)),Beat,Duration,Lyrics(N,'Lyrics'));
            end;
            Beat := Beat+Duration; HighBeat := Max(HighBeat,Beat);
          end;
        end;
      end; Beat := HighBeat;
    end;
  end;
end;
function TSongParser.Finish: TMusicStudioSingingSource;
var I,J,Count: Integer; T,Prev: TSongTempo; R: TRawSongNote; N: TMusicStudioSingingNote;
  Vowels: TArray<string>;
  function Seconds(Beat: Double): Double;
  var Lo,Hi,Mid: Integer;
  begin Lo := 0; Hi := Tempos.Count;
    while Lo+1<Hi do begin Mid := (Lo+Hi) div 2; if Tempos[Mid].Beat<=Beat then Lo := Mid else Hi := Mid; end;
    Result := Tempos[Lo].Seconds+(Beat-Tempos[Lo].Beat)*60/Tempos[Lo].BPM;
  end;
begin
  Check; Tempos.Sort(TComparer<TSongTempo>.Construct(function(const A,B: TSongTempo): Integer
    begin Result := CompareValue(A.Beat,B.Beat); if Result=0 then Result := A.Order-B.Order; end));
  Prev := Tempos[0]; Prev.Seconds := 0;
  for I := 0 to Tempos.Count-1 do begin T := Tempos[I]; T.Seconds := Prev.Seconds+(T.Beat-Prev.Beat)*60/Prev.BPM; Tempos[I] := T; Prev := T; end;
  Notes.Sort(TComparer<TRawSongNote>.Construct(function(const A,B: TRawSongNote): Integer
    begin Result := CompareValue(A.Beat,B.Beat); if Result=0 then Result := A.Track-B.Track; end));
  Result := Default(TMusicStudioSingingSource); Result.Tracks := Tracks.ToArray; SetLength(Result.Notes,Notes.Count); SetLength(Vowels,Tracks.Count); Count := 0;
  for I := 0 to Notes.Count-1 do begin
    Check; R := Notes[I]; N := Default(TMusicStudioSingingNote); N.StartSeconds := Seconds(R.Beat); N.EndSeconds := Seconds(R.EndBeat);
    if (N.EndSeconds>604800) or (N.EndSeconds<=N.StartSeconds) then raise Exception.Create('歌唱の長さが不正、または604800秒を超えています。');
    N.TrackIndex := R.Track; N.Key := R.Key; N.Velocity := 100; N.Lyric := R.Lyric;
    for J := 0 to High(Result.Tracks) do if Result.Tracks[J].Index=R.Track then begin
      N.Vowels := MusicStudioLyricVowels(R.Lyric,Vowels[J]); if N.Vowels<>'' then Vowels[J] := N.Vowels;
      Inc(Result.Tracks[J].NoteCount); if R.Lyric<>'' then begin Inc(Result.Tracks[J].LyricCount); Inc(Count); end;
      Result.Tracks[J].Duration := Max(Result.Tracks[J].Duration,N.EndSeconds); Break;
    end;
    Result.Notes[I] := N; Result.Duration := Max(Result.Duration,N.EndSeconds);
  end;
  if Count=0 then begin Result.Status := ssNoLyrics; Result.Message := '歌唱データは読み込めましたが、音符に対応する歌詞がありません。'; end
  else begin Result.Status := ssReady; Result.Message := Format('歌詞付き音符 %d件 / %dトラック',[Count,Tracks.Count]); end;
end;
function LoadMusicStudioStructuredSong(const Path: string; Cancel: TThread): TMusicStudioSingingSource;
var Parser: TSongParser; Doc: IXMLDocument; Text,Ext: string; HR: HRESULT;
begin
  HR := CoInitializeEx(nil,COINIT_MULTITHREADED); Parser := TSongParser.Create(Cancel);
  try
    Parser.Check; Text := ReadSongText(Path); Parser.Check; Ext := LowerCase(ExtractFileExt(Path));
    if Ext='.ust' then Parser.UST(Text)
    else begin
      Doc := XML(Text);
      if Ext='.vsqx' then Parser.VSQX(Doc.DocumentElement)
      else if (Ext='.mscx') or (Ext='.mscz') then Parser.MuseScore(Doc.DocumentElement)
      else Parser.MusicXML(Doc.DocumentElement);
    end;
    Result := Parser.Finish;
  finally Doc := nil; Parser.Free; if (HR=S_OK) or (HR=S_FALSE) then CoUninitialize; end;
end;
end.
