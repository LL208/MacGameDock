// Regression runner: no network or account required.
using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Reflection;
using System.Runtime.Loader;
using SteamKit2;
using SteamKit2.Internal;
var assembly=Assembly.Load("DepotDownloader");
var session=assembly.GetType("DepotDownloader.Steam3Session");
byte[] Schema(string type){
 using var stream=new MemoryStream();using var writer=new BinaryWriter(stream);
 void Text(string s){writer.Write(Encoding.UTF8.GetBytes(s));writer.Write((byte)0);}
 void Object(string name){writer.Write((byte)0);Text(name);}
 void Value(string name,string value){writer.Write((byte)1);Text(name);Text(value);}
 void End(){writer.Write((byte)8);}
 Object("10");Object("stats");Object("1");Value("type",type);Object("bits");
 for(int i=0;i<2;i++){Object(i.ToString());Value("name",i==0?"OLD":"NEW");Object("display");Object("name");Value("english",i==0?"Old":"New");End();End();End();}
 End();End();End();End();End();return stream.ToArray();
}
var parse=session.GetMethod("ParseAchievements",BindingFlags.Static|BindingFlags.NonPublic);
var build=session.GetMethod("BuildStoreRequest",BindingFlags.Static|BindingFlags.NonPublic);
foreach(var type in new[]{"ACHIEVEMENTS","BITS","4"}){
 var current=new CMsgClientGetUserStatsResponse {game_id=10,eresult=1,crc_stats=123,schema=Schema(type)};
 var block=new CMsgClientGetUserStatsResponse.Achievement_Blocks {achievement_id=1};block.unlock_time.AddRange(new uint[]{100,0});current.achievement_blocks.Add(block);
 var values=(System.Collections.IList)parse.Invoke(null,new object[]{(uint)10,current});if(values.Count!=2)throw new Exception("Schema type "+type+" not parsed");
 var request=(CMsgClientStoreUserStats2)build.Invoke(null,new object[]{(uint)10,(ulong)76561198000000000,current,new[]{"NEW"}});
 if(request.stats.Count!=1||request.stats[0].stat_value!=3||request.explicit_reset||request.settee_steam_id!=76561198000000000||request.crc_stats!=123)throw new Exception("Invalid merge");
 try {build.Invoke(null,new object[]{(uint)10,(ulong)76561198000000000,current,new[]{"UNKNOWN"}});throw new Exception("Unknown accepted");}catch(TargetInvocationException){}
}
Console.WriteLine("Steam schema/StoreStats regression: text and numeric types, preservation of existing bits, no reset, unknown-name rejection passed without network.");

var uploadType=session.GetNestedType("DeckCloudUploadRequest",BindingFlags.NonPublic);
var validateUpload=session.GetMethod("ValidateUpload",BindingFlags.NonPublic|BindingFlags.Static);
string UploadJson(string name,string source,string owner="76561198000000000") => System.Text.Json.JsonSerializer.Serialize(new {steamID=owner,appID=10,changeNumber="1",files=new[]{new{name,source,sha1=new string('a',40),size=4,timestamp=1700000000}}});
void Validate(string json,bool expected) {
 var value=System.Text.Json.JsonSerializer.Deserialize(json,uploadType);
 try {validateUpload.Invoke(null,new[]{value,(object)(uint)10,"76561198000000000"});if(!expected)throw new Exception("Unsafe cloud upload accepted");}
 catch(TargetInvocationException){if(expected)throw;}
}
Validate(UploadJson("%GameInstall%Saves/slot.dat","0.save"),true);
Validate(UploadJson("../outside","0.save"),false);
Validate(UploadJson("save.dat","../outside"),false);
Validate(UploadJson("save.dat","0.save","76561198000000001"),false);
Console.WriteLine("Cloud upload request validation: account isolation, safe names and staging containment passed without network.");
var limiterType=assembly.GetType("DepotDownloader.DeckBandwidthLimiter");
var limiter=Activator.CreateInstance(limiterType,BindingFlags.Instance|BindingFlags.NonPublic,null,new object[]{1024},null);
var reserve=limiterType.GetMethod("Reserve",BindingFlags.Instance|BindingFlags.NonPublic);
double Reserve(uint bytes,double now) => (double)reserve.Invoke(limiter,new object[]{bytes,now});
if(Math.Abs(Reserve(1048576,0)-1000)>0.001 || Math.Abs(Reserve(1048576,0)-2000)>0.001 || Math.Abs(Reserve(1048576,5000)-1000)>0.001) throw new Exception("Bandwidth reservations do not bound aggregate parallel throughput");
Console.WriteLine("Aggregate bandwidth limiter: concurrent reservations and idle recovery passed without network or sleeps.");

// A disconnected session must never dereference SteamID or touch the destination.
var disconnected = System.Runtime.CompilerServices.RuntimeHelpers.GetUninitializedObject(session);
var inventory = session.GetMethod("ExportDeckCloudInventory");
try { ((System.Threading.Tasks.Task)inventory.Invoke(disconnected, new object[]{(uint)10, "unused-cloud-inventory.json"})).GetAwaiter().GetResult(); throw new Exception("Disconnected session accepted"); }
catch (Exception e) when (e.GetType().Name == "DeckCloudException") { if ((string)e.GetType().GetProperty("Code").GetValue(e) != "steam_NoConnection") throw; }
Console.WriteLine("Disconnected cloud inventory: typed connection error, no output written.");
var localization = session.GetMethod("Localized", BindingFlags.NonPublic | BindingFlags.Static);
var languageContext = (System.Threading.AsyncLocal<string>)session.GetField("deckLanguage", BindingFlags.NonPublic | BindingFlags.Static).GetValue(null);
var localizedNode = new KeyValue("title");
localizedNode.Children.Add(new KeyValue("italian", "Trofeo"));
localizedNode.Children.Add(new KeyValue("english", "Achievement"));
languageContext.Value = "italian";
if ((string)localization.Invoke(null, new object[]{localizedNode}) != "Trofeo") throw new Exception("Italian achievement localization failed");
languageContext.Value = "english";
if ((string)localization.Invoke(null, new object[]{localizedNode}) != "Achievement") throw new Exception("Live achievement language switch failed");
languageContext.Value = "italian";
var fallbackNode = new KeyValue("title"); fallbackNode.Children.Add(new KeyValue("english", "Fallback"));
if ((string)localization.Invoke(null, new object[]{fallbackNode}) != "Fallback") throw new Exception("Achievement English fallback failed");
languageContext.Value = null;
Console.WriteLine("Achievement language selection and live language changes: Italian, English and missing-translation fallback passed.");
