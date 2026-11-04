unit SYNC_MusicStudio_FramebufferCapture;

// Reads the host's pre-overlay composited framebuffer during the video callback.
// Each effect owns its staging resources; only copied pixels leave this unit.
interface

uses System.SyncObjs, AviUtl2FilterTypes, Winapi.D3D11, Winapi.DXGIFormat;

type
  TMusicStudioFramebufferCapture = class
  private
    FLock: TCriticalSection;
    FDevice: ID3D11Device;
    FStaging: ID3D11Texture2D;
    FWidth,FHeight: Integer;
    FFormat: DXGI_FORMAT;
  public
    constructor Create;
    destructor Destroy; override;
    function Capture(GetTexture: TFILTER_PROC_VIDEO_GET_TEX2D;
      out Pixels: TArray<TPIXEL_RGBA>; out Width,Height: Integer;
      out Status: string): Boolean;
  end;

implementation

uses System.SysUtils, System.Math;

type
  TPixelWords = array[0..3] of Word;
  PPixelWords = ^TPixelWords;

function HalfToSingle(Value: Word): Single;
var Exponent: Integer; Mantissa,SignBits,Bits: Cardinal;
begin
  SignBits := Cardinal(Value and $8000) shl 16;
  Exponent := (Value shr 10) and $1F; Mantissa := Value and $03FF;
  if Exponent=0 then begin
    if Mantissa=0 then Bits := SignBits
    else begin
      Exponent := -14;
      while Mantissa and $0400=0 do begin Mantissa := Mantissa shl 1; Dec(Exponent); end;
      Bits := SignBits or (Cardinal(Exponent+127) shl 23) or ((Mantissa and $03FF) shl 13);
    end;
  end else if Exponent=$1F then Bits := SignBits or $7F800000 or (Mantissa shl 13)
  else Bits := SignBits or (Cardinal(Exponent+112) shl 23) or (Mantissa shl 13);
  Result := PSingle(@Bits)^;
end;

function FloatToByte(Value: Single): Byte;
begin
  if IsNan(Value) or (Value<=0) then Exit(0);
  if Value>=1 then Exit(255);
  Result := Round(Value*255);
end;

constructor TMusicStudioFramebufferCapture.Create;
begin inherited; FLock := TCriticalSection.Create; end;

destructor TMusicStudioFramebufferCapture.Destroy;
begin FStaging := nil; FDevice := nil; FLock.Free; inherited; end;

function TMusicStudioFramebufferCapture.Capture(GetTexture: TFILTER_PROC_VIDEO_GET_TEX2D;
  out Pixels: TArray<TPIXEL_RGBA>; out Width,Height: Integer;
  out Status: string): Boolean;
var Texture: ID3D11Texture2D; Device: ID3D11Device; Context: ID3D11DeviceContext;
    Desc,StagingDesc: D3D11_TEXTURE2D_DESC; Mapped: D3D11_MAPPED_SUBRESOURCE;
    Raw: Pointer; Row: PByte; Words: PPixelWords; X,Y,Bpp: Integer; P: PPIXEL_RGBA;
begin
  Result := False; Pixels := nil; Width := 0; Height := 0;
  Status := 'フレームバッファ取得APIなし';
  if not Assigned(GetTexture) then Exit;
  FLock.Acquire;
  try
    try
      Raw := GetTexture(); Status := 'フレームバッファ未取得'; if Raw=nil then Exit;
      Texture := ID3D11Texture2D(Raw); Texture.GetDesc(Desc);
      Status := 'フレームバッファのサイズが範囲外';
      if (Desc.Width<1) or (Desc.Height<1) or (Desc.Width>8192) or (Desc.Height>8192) or
        (Int64(Desc.Width)*Desc.Height>33554432) then Exit;
      Bpp := 0;
      case Desc.Format of
        DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: Bpp := 4;
        DXGI_FORMAT_R16G16B16A16_UNORM,DXGI_FORMAT_R16G16B16A16_FLOAT: Bpp := 8;
      end;
      Status := Format('未対応フレームバッファ形式 %d',[Ord(Desc.Format)]);
      if Bpp=0 then Exit;
      Status := '未対応の複数サンプルフレームバッファ'; if Desc.SampleDesc.Count<>1 then Exit;
      Texture.GetDevice(Device); Status := 'D3Dデバイス未取得'; if Device=nil then Exit;
      if (FStaging=nil) or (Pointer(FDevice)<>Pointer(Device)) or
        (FWidth<>Integer(Desc.Width)) or (FHeight<>Integer(Desc.Height)) or (FFormat<>Desc.Format) then begin
        FStaging := nil; FDevice := nil;
        StagingDesc := Desc; StagingDesc.MipLevels := 1; StagingDesc.ArraySize := 1;
        StagingDesc.Usage := D3D11_USAGE_STAGING; StagingDesc.BindFlags := 0;
        StagingDesc.CPUAccessFlags := D3D11_CPU_ACCESS_READ; StagingDesc.MiscFlags := 0;
        Status := 'フレームバッファ読戻し用画像を作成できない';
        if Device.CreateTexture2D(StagingDesc,nil,FStaging)<0 then Exit;
        FDevice := Device; FWidth := Desc.Width; FHeight := Desc.Height; FFormat := Desc.Format;
      end;
      Device.GetImmediateContext(Context); Status := 'D3Dコンテキスト未取得'; if Context=nil then Exit;
      Context.CopyResource(FStaging,Texture); FillChar(Mapped,SizeOf(Mapped),0);
      Status := 'フレームバッファを読み戻せない';
      if Context.Map(FStaging,0,D3D11_MAP_READ,0,Mapped)<0 then Exit;
      try
        Status := 'フレームバッファ行サイズ不正';
        if Mapped.RowPitch<Desc.Width*Cardinal(Bpp) then Exit;
        SetLength(Pixels,NativeInt(Desc.Width)*Desc.Height);
        for Y := 0 to Integer(Desc.Height)-1 do begin
          Row := PByte(NativeUInt(Mapped.pData)+NativeUInt(Y)*Mapped.RowPitch);
          P := @Pixels[Y*Integer(Desc.Width)];
          case Desc.Format of
            DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
              Move(Row^,P^,NativeInt(Desc.Width)*4);
            DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
              for X := 0 to Integer(Desc.Width)-1 do begin
                P^.R := Row[2]; P^.G := Row[1]; P^.B := Row[0]; P^.A := Row[3]; Inc(Row,4); Inc(P);
              end;
            DXGI_FORMAT_R16G16B16A16_UNORM,DXGI_FORMAT_R16G16B16A16_FLOAT: begin
              Words := PPixelWords(Row);
              for X := 0 to Integer(Desc.Width)-1 do begin
                if Desc.Format=DXGI_FORMAT_R16G16B16A16_UNORM then begin
                  P^.R := Words[0] div 257; P^.G := Words[1] div 257;
                  P^.B := Words[2] div 257; P^.A := Words[3] div 257;
                end else begin
                  P^.R := FloatToByte(HalfToSingle(Words[0])); P^.G := FloatToByte(HalfToSingle(Words[1]));
                  P^.B := FloatToByte(HalfToSingle(Words[2])); P^.A := FloatToByte(HalfToSingle(Words[3]));
                end;
                Inc(Words); Inc(P);
              end;
            end;
          end;
        end;
      finally Context.Unmap(FStaging,0); end;
      Width := Desc.Width; Height := Desc.Height;
      Status := Format('フレームバッファ %d x %d / DXGI %d',[Width,Height,Ord(Desc.Format)]);
      Result := True;
    except on E: Exception do begin Pixels := nil; Width := 0; Height := 0; Status := '背景取得失敗: '+E.Message; end; end;
  finally FLock.Release; end;
end;

end.
