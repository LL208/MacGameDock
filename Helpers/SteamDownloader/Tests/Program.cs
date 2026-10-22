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
