// Copied from AviUtl2PluginLib/Lib/PSDArtEditor/Persistence/PSD/ArtPsdOrigin.pas.
// Read and render only through SYNC_MusicStudio_PsdLayers; source PSD files are never saved.
unit SYNC_MusicStudio_ArtPsdOrigin;

interface

uses System.SysUtils;

// These functions never infer origin from a file name or directory.
function NewArtPsdOrigin: string;
function VerifyArtPsdOrigin(const Data: TBytes; out OriginId: string): Boolean;
function SealArtPsdOrigin(const Data: TBytes; const OriginId: string): TBytes;

implementation

uses System.Classes, System.IOUtils, System.Hash, Winapi.Windows, SYNC_MusicStudio_ArtDocument;

const
  ORIGIN_RESOURCE_ID = 4094;
  ORIGIN_RESOURCE_NAME: AnsiString = 'Syncroh2.PSD.Origin';
  ORIGIN_MAGIC: AnsiString = 'SRH2PSD'#1;
  ORIGIN_PAYLOAD_SIZE = 8 + 16 + 32;
  ORIGIN_MAC_OFFSET = 8 + 16;
  KEY_SIZE = 32;
  DPAPI_NO_UI = 1;

type
  TOriginBlob = record
    Size: DWORD;
    Data: PByte;
  end;
  TOriginLayout = record
    ResourceLengthOffset, ResourceStart, ResourceEnd: Integer;
    MarkerStart, MarkerEnd, PayloadStart: Integer;
  end;

function OriginProtect(var Input: TOriginBlob; Description: PWideChar;
  Entropy, Reserved, Prompt: Pointer; Flags: DWORD; out Output: TOriginBlob): BOOL;
  stdcall; external 'crypt32.dll' name 'CryptProtectData';
function OriginUnprotect(var Input: TOriginBlob; Description, Entropy, Reserved,
  Prompt: Pointer; Flags: DWORD; out Output: TOriginBlob): BOOL;
  stdcall; external 'crypt32.dll' name 'CryptUnprotectData';
function OriginRandom(Algorithm: THandle; Buffer: PByte; Size, Flags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptGenRandom';
function OriginOpenHashProvider(out Algorithm: THandle; Id, Provider: PWideChar;
  Flags: ULONG): LongInt; stdcall; external 'bcrypt.dll' name 'BCryptOpenAlgorithmProvider';
function OriginHashProperty(Algorithm: THandle; Name: PWideChar; Data: PByte;
  Size: ULONG; out Written: ULONG; Flags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptGetProperty';
function OriginCreateHash(Algorithm: THandle; out Hash: THandle; Buffer: PByte;
  BufferSize: ULONG; Secret: PByte; SecretSize, Flags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptCreateHash';
function OriginHashData(Hash: THandle; Data: PByte; Size, Flags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptHashData';
function OriginFinishHash(Hash: THandle; Data: PByte; Size, Flags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptFinishHash';
function OriginDestroyHash(Hash: THandle): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptDestroyHash';
function OriginCloseHashProvider(Algorithm: THandle; Flags: ULONG): LongInt;
  stdcall; external 'bcrypt.dll' name 'BCryptCloseAlgorithmProvider';

procedure ClearBytes(var Value: TBytes);
begin
  if Length(Value)>0 then FillChar(Value[0],Length(Value),0);
  Value := nil;
end;

function OriginKeyPath: string;
var Root: string;
begin
  Root := GetEnvironmentVariable('LOCALAPPDATA');
  if Root='' then raise EArtFormat.Create('PSD認証鍵の保存先を取得できません。');
  Result := TPath.Combine(Root,'Syncroh2\PSDArtEditor\origin.key');
end;

function LoadOriginKey(CreateIfMissing: Boolean): TBytes;
var Mutex: THandle; WaitResult: DWORD; Path,Temp: string; G: TGUID;
    Input,Output: TOriginBlob; Encrypted,NewKey: TBytes;
begin
  Result := nil; Temp := ''; NewKey := nil;
  Path := OriginKeyPath;
  Mutex := CreateMutex(nil,False,'Local\Syncroh2.PSD.Origin.Key');
  if Mutex=0 then RaiseLastOSError;
  try
    WaitResult := WaitForSingleObject(Mutex,5000);
    if not (WaitResult in [WAIT_OBJECT_0,WAIT_ABANDONED]) then
      raise EArtFormat.Create('PSD認証鍵を使用中です。再試行してください。');
    try
      if not TFile.Exists(Path) then begin
        if not CreateIfMissing then Exit;
        SetLength(NewKey,KEY_SIZE);
        if OriginRandom(0,@NewKey[0],KEY_SIZE,2)<0 then
          raise EArtFormat.Create('PSD認証鍵を生成できません。');
        Input.Size := KEY_SIZE; Input.Data := @NewKey[0];
        FillChar(Output,SizeOf(Output),0);
        if not OriginProtect(Input,'Syncroh2 PSD origin',nil,nil,nil,DPAPI_NO_UI,Output) then
          RaiseLastOSError;
        try
          SetLength(Encrypted,Output.Size);
          Move(Output.Data^,Encrypted[0],Output.Size);
        finally LocalFree(HLOCAL(Output.Data)); end;
        ForceDirectories(ExtractFilePath(Path)); CreateGUID(G);
        Temp := Path+'.'+GUIDToString(G)+'.tmp';
        TFile.WriteAllBytes(Temp,Encrypted);
        // Never replace an existing key, even during concurrent first creation.
        if not MoveFileEx(PChar(Temp),PChar(Path),MOVEFILE_WRITE_THROUGH) then RaiseLastOSError;
        Temp := '';
      end;
      if TFile.GetSize(Path)>65536 then raise EArtFormat.Create('PSD認証鍵が破損しています。');
      Encrypted := TFile.ReadAllBytes(Path);
      if Length(Encrypted)=0 then raise EArtFormat.Create('PSD認証鍵が空です。');
      Input.Size := Length(Encrypted); Input.Data := @Encrypted[0];
      FillChar(Output,SizeOf(Output),0);
      if not OriginUnprotect(Input,nil,nil,nil,nil,DPAPI_NO_UI,Output) then RaiseLastOSError;
      try
        if Output.Size<>KEY_SIZE then raise EArtFormat.Create('PSD認証鍵の形式が不正です。');
        SetLength(Result,KEY_SIZE); Move(Output.Data^,Result[0],KEY_SIZE);
      finally
        if Output.Size>0 then FillChar(Output.Data^,Output.Size,0);
        LocalFree(HLOCAL(Output.Data));
      end;
    finally ReleaseMutex(Mutex); end;
  finally
    CloseHandle(Mutex); ClearBytes(NewKey);
    if (Temp<>'') and TFile.Exists(Temp) then TFile.Delete(Temp);
  end;
end;

procedure CheckRange(const Data: TBytes; Offset: Integer; Count: Int64);
begin
  if (Offset<0) or (Count<0) or (Count>Int64(Length(Data))-Offset) then
    raise EArtFormat.Create('PSD origin resource boundary exceeded');
end;

function ReadU32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  CheckRange(Data,Offset,4);
  Result := (Cardinal(Data[Offset]) shl 24) or (Cardinal(Data[Offset+1]) shl 16) or
    (Cardinal(Data[Offset+2]) shl 8) or Data[Offset+3];
end;

procedure WriteU32(var Data: TBytes; Offset: Integer; Value: Cardinal);
begin
  CheckRange(Data,Offset,4);
  Data[Offset] := Byte(Value shr 24); Data[Offset+1] := Byte(Value shr 16);
  Data[Offset+2] := Byte(Value shr 8); Data[Offset+3] := Byte(Value);
end;

function BytesEqual(const Data: TBytes; Offset: Integer; const Value: AnsiString): Boolean;
begin
  CheckRange(Data,Offset,Length(Value));
  Result := (Value='') or CompareMem(@Data[Offset],@Value[1],Length(Value));
end;

function OriginLayout(const Data: TBytes): TOriginLayout;
var P,Start,NameStart,NameLength,Id: Integer; Size: Cardinal;
begin
  CheckRange(Data,0,34);
  if not BytesEqual(Data,0,'8BPS') or (Data[4]<>0) or (Data[5]<>1) then
    raise EArtFormat.Create('PSD origin requires PSD version 1');
  Size := ReadU32(Data,26); CheckRange(Data,30,Int64(Size)+4);
  Result.ResourceLengthOffset := 30+Integer(Size);
  Size := ReadU32(Data,Result.ResourceLengthOffset);
  Result.ResourceStart := Result.ResourceLengthOffset+4;
  CheckRange(Data,Result.ResourceStart,Size);
  Result.ResourceEnd := Result.ResourceStart+Integer(Size);
  Result.MarkerStart := -1; Result.MarkerEnd := -1; Result.PayloadStart := -1;
  P := Result.ResourceStart;
  while P<Result.ResourceEnd do begin
    Start := P; CheckRange(Data,P,7);
    if not BytesEqual(Data,P,'8BIM') then raise EArtFormat.Create('Invalid PSD resource signature');
    Id := (Integer(Data[P+4]) shl 8) or Data[P+5];
    NameLength := Data[P+6]; NameStart := P+7;
    P := NameStart+NameLength+((NameLength+1) mod 2);
    Size := ReadU32(Data,P); Inc(P,4);
    if (P>Result.ResourceEnd) or (Int64(Size)+(Size mod 2)>Int64(Result.ResourceEnd)-P) then
      raise EArtFormat.Create('Invalid PSD resource length');
    if (Id=ORIGIN_RESOURCE_ID) and (NameLength=Length(ORIGIN_RESOURCE_NAME)) and
      BytesEqual(Data,NameStart,ORIGIN_RESOURCE_NAME) then begin
      if (Result.MarkerStart>=0) or (Size<>ORIGIN_PAYLOAD_SIZE) then
        raise EArtFormat.Create('Invalid or repeated PSD origin');
      Result.MarkerStart := Start; Result.PayloadStart := P;
      Result.MarkerEnd := P+Integer(Size)+Integer(Size mod 2);
    end;
    Inc(P,Integer(Size)+Integer(Size mod 2));
  end;
end;

function OriginMac(const Data, Key: TBytes; PayloadStart: Integer): TBytes;
var Algorithm,Hash: THandle; ObjectBuffer,Digest: TBytes;
    ObjectSize,DigestSize,Written: ULONG; Zeros: array[0..31] of Byte; Offset: Integer;
  procedure Check(Status: LongInt);
  begin
    if Status<0 then raise EArtFormat.CreateFmt('PSD SHA-256 failed (%.8x)',[Cardinal(Status)]);
  end;
begin
  Offset := PayloadStart+ORIGIN_MAC_OFFSET; CheckRange(Data,Offset,32);
  // Bind every byte, including UUID and resource layout, with the MAC field zeroed.
  // CNG computes the same SHA-256 digest without Delphi's per-block overhead.
  // Handles are local to this call, so concurrent verification shares no hash state.
  Algorithm := 0; Hash := 0; FillChar(Zeros,SizeOf(Zeros),0);
  try
    Check(OriginOpenHashProvider(Algorithm,'SHA256',nil,0));
    Check(OriginHashProperty(Algorithm,'ObjectLength',@ObjectSize,SizeOf(ObjectSize),Written,0));
    if (Written<>SizeOf(ObjectSize)) or (ObjectSize=0) or (ObjectSize>65536) then
      raise EArtFormat.Create('Invalid SHA-256 object size');
    Check(OriginHashProperty(Algorithm,'HashDigestLength',@DigestSize,SizeOf(DigestSize),Written,0));
    if (Written<>SizeOf(DigestSize)) or (DigestSize<>32) then
      raise EArtFormat.Create('Invalid SHA-256 digest size');
    SetLength(ObjectBuffer,ObjectSize); SetLength(Digest,DigestSize);
    Check(OriginCreateHash(Algorithm,Hash,@ObjectBuffer[0],ObjectSize,nil,0,0));
    if Offset>0 then Check(OriginHashData(Hash,@Data[0],Offset,0));
    Check(OriginHashData(Hash,@Zeros[0],SizeOf(Zeros),0));
    if Offset+32<Length(Data) then
      Check(OriginHashData(Hash,@Data[Offset+32],Length(Data)-Offset-32,0));
    Check(OriginFinishHash(Hash,@Digest[0],DigestSize,0));
    Result := THashSHA2.GetHMACAsBytes(Digest,Key);
  finally
    if Hash<>0 then OriginDestroyHash(Hash);
    if Algorithm<>0 then OriginCloseHashProvider(Algorithm,0);
    ClearBytes(ObjectBuffer); ClearBytes(Digest);
  end;
end;

function NewArtPsdOrigin: string;
var Key: TBytes; G: TGUID;
begin
  Key := LoadOriginKey(True);
  try CreateGUID(G); Result := GUIDToString(G); finally ClearBytes(Key); end;
end;

function VerifyArtPsdOrigin(const Data: TBytes; out OriginId: string): Boolean;
var Layout: TOriginLayout; Key,Mac: TBytes; G: TGUID; I,Difference: Integer;
begin
  Result := False; OriginId := ''; Key := nil;
  try
    try
      Layout := OriginLayout(Data);
      if (Layout.MarkerStart<0) or not BytesEqual(Data,Layout.PayloadStart,ORIGIN_MAGIC) then Exit;
      Move(Data[Layout.PayloadStart+8],G,SizeOf(G));
      if IsEqualGUID(G,TGUID.Empty) then Exit;
      Key := LoadOriginKey(False); if Length(Key)<>KEY_SIZE then Exit;
      Mac := OriginMac(Data,Key,Layout.PayloadStart); Difference := 0;
      for I := 0 to 31 do
        Difference := Difference or (Mac[I] xor Data[Layout.PayloadStart+ORIGIN_MAC_OFFSET+I]);
      if Difference<>0 then Exit;
      OriginId := GUIDToString(G); Result := True;
    except on E: Exception do begin OriginId := ''; Result := False; end; end;
  finally ClearBytes(Key); end;
end;

function SealArtPsdOrigin(const Data: TBytes; const OriginId: string): TBytes;
var Layout,SealedLayout: TOriginLayout; Stream: TMemoryStream;
    Key,Mac: TBytes; G: TGUID; Zero: Byte; Payload: array[0..ORIGIN_PAYLOAD_SIZE-1] of Byte;
    IdBytes: array[0..1] of Byte; SizeBytes: array[0..3] of Byte; CheckedId: string;
  procedure Append(Offset,Count: Integer);
  begin
    CheckRange(Data,Offset,Count);
    if Count>0 then Stream.WriteBuffer(Data[Offset],Count);
  end;
begin
  G := StringToGUID(OriginId);
  if IsEqualGUID(G,TGUID.Empty) then raise EArtFormat.Create('PSD作成情報がありません。');
  Layout := OriginLayout(Data); Stream := TMemoryStream.Create; Key := nil;
  try
    Append(0,Layout.ResourceStart);
    if Layout.MarkerStart<0 then Append(Layout.ResourceStart,Layout.ResourceEnd-Layout.ResourceStart)
    else begin
      Append(Layout.ResourceStart,Layout.MarkerStart-Layout.ResourceStart);
      Append(Layout.MarkerEnd,Layout.ResourceEnd-Layout.MarkerEnd);
    end;
    Stream.WriteBuffer(PAnsiChar('8BIM')^,4);
    IdBytes[0] := Byte(ORIGIN_RESOURCE_ID shr 8); IdBytes[1] := Byte(ORIGIN_RESOURCE_ID);
    Stream.WriteBuffer(IdBytes,2); Zero := Length(ORIGIN_RESOURCE_NAME);
    Stream.WriteBuffer(Zero,1); Stream.WriteBuffer(ORIGIN_RESOURCE_NAME[1],Length(ORIGIN_RESOURCE_NAME));
    Zero := 0; if ((Length(ORIGIN_RESOURCE_NAME)+1) mod 2)<>0 then Stream.WriteBuffer(Zero,1);
    FillChar(SizeBytes,SizeOf(SizeBytes),0); SizeBytes[3] := ORIGIN_PAYLOAD_SIZE;
    Stream.WriteBuffer(SizeBytes,4); FillChar(Payload,SizeOf(Payload),0);
    Move(ORIGIN_MAGIC[1],Payload[0],Length(ORIGIN_MAGIC)); Move(G,Payload[8],SizeOf(G));
    Stream.WriteBuffer(Payload,SizeOf(Payload));
    if Stream.Size+Length(Data)-Layout.ResourceEnd>ART_MAX_BYTES then
      raise EArtFormat.Create('PSD origin exceeds file size limit');
    var ResourceSize := Stream.Size-Layout.ResourceStart;
    Append(Layout.ResourceEnd,Length(Data)-Layout.ResourceEnd);
    SetLength(Result,Stream.Size); Move(Stream.Memory^,Result[0],Length(Result));
    WriteU32(Result,Layout.ResourceLengthOffset,Cardinal(ResourceSize));
    SealedLayout := OriginLayout(Result); Key := LoadOriginKey(False);
    if Length(Key)<>KEY_SIZE then raise EArtFormat.Create('PSD認証鍵がありません。新規作成からやり直してください。');
    Mac := OriginMac(Result,Key,SealedLayout.PayloadStart);
    Move(Mac[0],Result[SealedLayout.PayloadStart+ORIGIN_MAC_OFFSET],32);
    if not VerifyArtPsdOrigin(Result,CheckedId) or (CheckedId<>GUIDToString(G)) then
      raise EArtFormat.Create('PSD作成情報の検証に失敗しました。');
  finally ClearBytes(Key); Stream.Free; end;
end;

end.
