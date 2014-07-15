unit XcpTransport;
//***************************************************************************************
//  Description: XCP transport layer for SCI.
//    File Name: XcpTransport.pas
//
//---------------------------------------------------------------------------------------
//                          C O P Y R I G H T
//---------------------------------------------------------------------------------------
//   Copyright (c) 2014 by Feaser    http://www.feaser.com    All rights reserved
//
//   This software has been carefully tested, but is not guaranteed for any particular
// purpose. The author does not offer any warranties and does not guarantee the accuracy,
//   adequacy, or completeness of the software and is not responsible for any errors or
//              omissions or the results obtained from use of the software.
//
//---------------------------------------------------------------------------------------
//                            L I C E N S E
//---------------------------------------------------------------------------------------
// This file is part of OpenBLT. OpenBLT is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option) any later
// version.
//
// OpenBLT is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along with OpenBLT.
// If not, see <http://www.gnu.org/licenses/>.
//
// A special exception to the GPL is included to allow you to distribute a combined work
// that includes OpenBLT without being obliged to provide the source code for any
// proprietary components. The exception text is included at the bottom of the license
// file <license.html>.
//
//***************************************************************************************
interface


//***************************************************************************************
// Includes
//***************************************************************************************
uses
  Windows, Messages, SysUtils, Classes, Forms, IniFiles, Winsock, WSocket;


//***************************************************************************************
// Global Constants
//***************************************************************************************
const kMaxPacketSize = 256 + 4; // 4 extra for TCP/IP counter overhead
const kTcpConnectedTimeoutMs = 1000; // timeout for connecting the socket


//***************************************************************************************
// Type Definitions
//***************************************************************************************
type
  TXcpTransportInfo = (kNone, kConnected, kResponse, kError);


type
  TXcpTransport = class(TObject)
  private
    comEventInfo : TXcpTransportInfo;
    comEvent     : THandle;
    socket       : TWSocket;
    hostname     : string;
    port         : string;
    croCounter   : LongWord;
    procedure OnSocketSessionConnected(Sender: TObject; Error: Word);
    procedure OnSocketDataAvailable(Sender: TObject; ErrCode: Word);
    function  MsgWaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
  public
    packetData   : array[0..kMaxPacketSize-1] of Byte;
    packetLen    : Word;
    constructor Create;
    procedure   Configure(iniFile : string);
    function    Connect: Boolean;
    function    SendPacket(timeOutms: LongWord): Boolean;
    procedure   Disconnect;
    destructor  Destroy; override;
  end;


implementation

//***************************************************************************************
// NAME:           Create
// PARAMETER:      none
// RETURN VALUE:   none
// DESCRIPTION:    Class constructore
//
//***************************************************************************************
constructor TXcpTransport.Create;
begin
  // call inherited constructor
  inherited Create;

  // reset can event info
  comEventInfo := kNone;

  // create the event that requires manual reset
  comEvent := CreateEvent(nil, True, False, nil);

  if comEvent = 0 then
    Application.MessageBox( 'Could not obtain event placeholder.',
                            'Error', MB_OK or MB_ICONERROR );

  // create a socket instance
  socket := TWSocket.Create(nil);

  // set the socket event handlers
  socket.OnSessionConnected := OnSocketSessionConnected;
  socket.OnDataAvailable := OnSocketDataAvailable;

  // init CRO counter value
  croCounter := 1;

  // reset packet length
  packetLen := 0;
end; //*** end of Create ***


//***************************************************************************************
// NAME:           Destroy
// PARAMETER:      none
// RETURN VALUE:   none
// DESCRIPTION:    Class destructor
//
//***************************************************************************************
destructor TXcpTransport.Destroy;
begin
  // release socket instance
  socket.Free;

  // call inherited destructor
  inherited;
end; //*** end of Destroy ***


//***************************************************************************************
// NAME:           Configure
// PARAMETER:      filename of the INI
// RETURN VALUE:   none
// DESCRIPTION:    Configures both this class from the settings in the INI.
//
//***************************************************************************************
procedure TXcpTransport.Configure(iniFile : string);
var
  settingsIni : TIniFile;
begin
	// read XCP configuration from INI
  if FileExists(iniFile) then
  begin
    // create ini file object
    settingsIni := TIniFile.Create(iniFile);

    // configure hostname
    hostname := settingsIni.ReadString('net', 'hostname', '169.254.19.63');

    // configure port
    port := settingsIni.ReadString('net', 'port', '1000');

    // release ini file object
    settingsIni.Free;
  end
  else
  begin
    // configure defeault hostname
    hostname := '169.254.19.63';

    // configure default port
    port := '1000';
  end;

end; //*** end of Configure ***


//***************************************************************************************
// NAME:           Connect
// PARAMETER:      none
// RETURN VALUE:   True if connected, False otherwise.
// DESCRIPTION:    Connects the transport layer device.
//
//***************************************************************************************
function TXcpTransport.Connect: Boolean;
var
  waitResult: Integer;
begin
  // make sure the event is reset
  ResetEvent(comEvent);
  comEventInfo := kNone;

  // init CRO counter value
  croCounter := 1;

  // make sure the socket is closed
  if socket.State <> wsClosed then
  begin
    socket.Close;
    socket.WaitForClose;
  end;

  // set the hostname, port and protocol
  socket.Addr := hostname;
  socket.Port := port;
  socket.Proto := 'tcp';

  // submit the connect request
  socket.Connect;

  // connection is being established. Now wait for the connected event
  waitResult := MsgWaitForSingleObject(comEvent, kTcpConnectedTimeoutMs);

  if waitResult <> WAIT_OBJECT_0 then
  begin
    // no com event triggered so either a timeout or internal error occurred
    result := false;
    Exit;
  end;

  // com event was triggered. now check that it is actually not an error
  if comEventInfo <> kConnected then
  begin
    result := false;
    Exit;
  end;
  // successfully connected
  result := true;
end; //*** end of Connect ***


//***************************************************************************************
// NAME:           SendPacket
// PARAMETER:      the time[ms] allowed for the reponse from the slave to come in.
// RETURN VALUE:   True if response received from slave, False otherwise
// DESCRIPTION:    Sends the XCP packet using the data in 'packetData' and length in
//                 'packetLen' and waits for the response to come in.
//
//***************************************************************************************
function TXcpTransport.SendPacket(timeOutms: LongWord): Boolean;
var
  msgData : array of Byte;
  cnt     : byte;
  waitResult: Integer;
begin
  // make sure the event is reset
  ResetEvent(comEvent);
  comEventInfo := kNone;

  // init the return value
  result := false;

  // prepare the packet. the first 4 bytes contain the CRO counter followed by the actual
  // packet data
  SetLength(msgData, packetLen+4);

  // first store the CRO counter
  msgData[0] := Byte(croCounter);
  msgData[1] := Byte(croCounter shr  8);
  msgData[2] := Byte(croCounter shr 16);
  msgData[3] := Byte(croCounter shr 24);

  // increment the CRO counter for the next packet
  croCounter := croCounter + 1;

  // copy the packet data
  for cnt := 0 to packetLen-1 do
  begin
    msgData[cnt+4] := packetData[cnt];
  end;

  // submit the packet transmission request
  if socket.Send(@msgData[0], packetLen+4) = -1 then
  begin
    // unable to submit tx request
    Exit;
  end;

  // packet is being transmitted. Now wait for the response to come in
  waitResult := MsgWaitForSingleObject(comEvent, timeOutms);

  if waitResult <> WAIT_OBJECT_0 then
  begin
    // no com event triggered so either a timeout or internal error occurred
    result := False;
    Exit;
  end;

  // com event was triggered. now check if the reponse was correctly received
  if comEventInfo <> kResponse then
  begin
    result := False;
    Exit;
  end;

  // packet successfully transmitted and response packet received
  result := True;
end; //*** end of SendPacket ***


//***************************************************************************************
// NAME:           Disconnect
// PARAMETER:      none
// RETURN VALUE:   none
// DESCRIPTION:    Disconnects the transport layer device.
//
//***************************************************************************************
procedure TXcpTransport.Disconnect;
begin
  // close the socket
  socket.Close;
  socket.WaitForClose;
end; //*** end of Disconnect ***


//***************************************************************************************
// NAME:           OnSocketSessionConnected
// PARAMETER:      Sender is the source that triggered the event.
//                 Error contains possible connection error information.
// RETURN VALUE:   none
// DESCRIPTION:    Socket connected event handler
//
//***************************************************************************************
procedure TXcpTransport.OnSocketSessionConnected(Sender: TObject; Error: Word);
begin
  // set event flag
  if Error <> 0 then
    comEventInfo := kError
  else
    comEventInfo := kConnected;

  // trigger the event
  SetEvent(comEvent);
end; //*** end of OnSocketSessionConnected ***


//***************************************************************************************
// NAME:           OnSocketDataAvailable
// PARAMETER:      Sender is the source that triggered the event.
//                 Error contains possible data reception error information.
// RETURN VALUE:   none
// DESCRIPTION:    Socket data reception event handler
//
//***************************************************************************************
procedure TXcpTransport.OnSocketDataAvailable(Sender: TObject; ErrCode: Word);
var
  tempBuffer : array[0..kMaxPacketSize-1] of Byte;
  count      : Integer;
  idx        : Integer;
begin
  count := socket.Receive(@tempBuffer[0], kMaxPacketSize);
  // the first 4 bytes contains the dto counter in which we are not really interested
  packetLen := count - 4;
  // store the response data
  for idx := 0 to packetLen-1 do
  begin
    packetData[idx] := tempBuffer[idx+4];
  end;

  if packetLen = 0 then
    // set event flag
    comEventInfo := kError
  else
    // set event flag
    comEventInfo := kResponse;

  // trigger the event
  SetEvent(comEvent);
end; //*** end of OnSocketDataAvailable ***


//***************************************************************************************
// NAME:           MsgWaitForSingleObject
// PARAMETER:      none
// RETURN VALUE:   none
// DESCRIPTION:    Improved version of WaitForSingleObject. This version actually
//                 processes messages in the queue instead of blocking them.
//
//***************************************************************************************
function TXcpTransport.MsgWaitForSingleObject(hHandle: THandle; dwMilliseconds: DWORD): DWORD;
var
  dwEnd:DWord;
begin
  // compute the time when the WaitForSingleObject is supposed to time out
  dwEnd := GetTickCount + dwMilliseconds;

  repeat
    // wait for an event to happen or a message to be in the queue
    result := MsgWaitForMultipleObjects(1, hHandle, False, dwMilliseconds, QS_ALLINPUT);

    // a message was in the queue?
    if result = WAIT_OBJECT_0 + 1 then
    begin
      // process these messages
      Application.ProcessMessages;
      socket.MessagePump;

      // check for timeout manually because if a message in the queue occurred, the
      // MsgWaitForMultipleObjects will be called again and the timer will start from
      // scratch. we need to make sure the correct timeout time is used.
      dwMilliseconds := GetTickCount;
      if dwMilliseconds < dwEnd then
      begin
        dwMilliseconds := dwEnd - dwMilliseconds;
      end
      else
      begin
        // timeout occured
        result := WAIT_TIMEOUT;
        Break;
      end;
    end
    else
    // the event occured?
    begin
      // we can stop
      Break;
    end;
  until True = False;
end; //*** end of MsgWaitForSingleObject ***


end.
//******************************** end of XcpTransport.pas ******************************

