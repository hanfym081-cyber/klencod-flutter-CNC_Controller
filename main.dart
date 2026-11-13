import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const Mach3Remote());
const bg=Color(0xFF171C22), panel=Color(0xFF252D36), green=Color(0xFF36D17C), orange=Color(0xFFFFA62B), red=Color(0xFFE53935);

class Mach3Remote extends StatelessWidget {
  const Mach3Remote({super.key});
  @override Widget build(BuildContext context)=>MaterialApp(
    debugShowCheckedModeBanner:false,title:'Mach3 Remote',
    theme:ThemeData(brightness:Brightness.dark,scaffoldBackgroundColor:bg,
      colorScheme:const ColorScheme.dark(primary:green),useMaterial3:true),
    home:const MainScreen());
}

class MachineState {
  final double x,y,z,feed,rpm; final bool spindle;
  const MachineState(this.x,this.y,this.z,this.feed,this.rpm,this.spindle);
}
class Move {
  final int line; final Offset start,end; final double z0,z1; final bool rapid; final List<Offset> points;
  const Move(this.line,this.start,this.end,this.z0,this.z1,this.rapid,this.points);
}
class ParsedProgram {
  final List<Move> moves; final List<MachineState> states;
  final double minX,maxX,minY,maxY;
  const ParsedProgram(this.moves,this.states,this.minX,this.maxX,this.minY,this.maxY);
}
class GCodeParser {
  static ParsedProgram parse(List<String> lines) {
    double x=0,y=0,z=0,unit=1,f=0,s=0,minX=0,maxX=0,minY=0,maxY=0;
    bool absolute=true,spindle=false; int motion=0;
    final moves=<Move>[], states=<MachineState>[];
    final re=RegExp(r'([A-Z])\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+))',caseSensitive:false);
    for(var i=0;i<lines.length;i++){
      final src=lines[i].replaceAll(RegExp(r'\([^)]*\)'), '').split(';').first.toUpperCase();
      final w=<String,List<double>>{};
      for(final m in re.allMatches(src)){final n=double.tryParse(m.group(2)!);if(n!=null)(w[m.group(1)!]??=[]).add(n);}
      double? v(String k)=>w[k]?.last;
      for(final g in w['G']??<double>[]){if(g==20)unit=25.4;if(g==21)unit=1;if(g==90)absolute=true;if(g==91)absolute=false;if(g==0)motion=0;if(g==1)motion=1;if(g==2)motion=2;if(g==3)motion=3;}
      if(v('F')!=null)f=v('F')!*unit;if(v('S')!=null)s=v('S')!;
      for(final m in w['M']??<double>[]){if(m==3||m==4)spindle=true;if(m==5)spindle=false;}
      final ox=x,oy=y,oz=z;
      if(v('X')!=null)x=absolute?v('X')!*unit:x+v('X')!*unit;
      if(v('Y')!=null)y=absolute?v('Y')!*unit:y+v('Y')!*unit;
      if(v('Z')!=null)z=absolute?v('Z')!*unit:z+v('Z')!*unit;
      if(x!=ox||y!=oy){
        final a=Offset(ox,oy),b=Offset(x,y),pts=<Offset>[a];
        if((motion==2||motion==3)&&(v('I')!=null||v('J')!=null)){
          final c=Offset(ox+(v('I')??0)*unit,oy+(v('J')??0)*unit),r=(a-c).distance;
          if(r>1e-6){final a0=math.atan2(a.dy-c.dy,a.dx-c.dx),a1=math.atan2(b.dy-c.dy,b.dx-c.dx);var sw=a1-a0;
            if(motion==2){while(sw>=0){sw-=2*math.pi;}}else{while(sw<=0){sw+=2*math.pi;}}
            final count=math.max(12,(sw.abs()*r/2).ceil());
            for(var j=1;j<=count;j++){final q=a0+sw*j/count;pts.add(Offset(c.dx+r*math.cos(q),c.dy+r*math.sin(q)));}pts[pts.length-1]=b;
          }else{pts.add(b);}
        }else{pts.add(b);}
        moves.add(Move(i,a,b,oz,z,motion==0,pts));
        for(final p in pts){minX=math.min(minX,p.dx);maxX=math.max(maxX,p.dx);minY=math.min(minY,p.dy);maxY=math.max(maxY,p.dy);}
      }
      states.add(MachineState(x,y,z,f,s,spindle));
    }
    return ParsedProgram(moves,states,minX,maxX,minY,maxY);
  }
}

class MainScreen extends StatefulWidget {const MainScreen({super.key});@override State<MainScreen> createState()=>_MainScreenState();}
class _MainScreenState extends State<MainScreen>{
  final names=['PROGRAM RUN','MDI','TOOL PATH','MANUAL JOG','OFFSETS','SETTINGS','DIAGNOSTICS','FILES','CONNECTION'];
  int page=0; String ip='192.168.1.100',port='8765',fileName='لم يتم اختيار ملف',fileInfo='',content='',work='G54',step='1.0',mdiStatus='جاهز';
  final mdi=TextEditingController(),scroll=ScrollController();
  List<String> lines=[]; ParsedProgram? parsed; Timer? timer;
  final offsets={for(final c in ['G54','G55','G56','G57','G58','G59'])c:{'X':0.0,'Y':0.0,'Z':0.0}};
  final signals=<String,bool>{'Emergency input':false,'X Home':false,'Y Home':false,'Z Home':false,'X Limit':false,'Y Limit':false,'Z Limit':false,'Probe':false,'Spindle':false,'Flood':false,'Mist':false};
  int line=0,done=0; double mx=0,my=0,mz=0,feed=0,rpm=0,fro=100,sro=100,jogSpeed=50;
  bool running=false,hold=false,estop=false,spindle=false,connected=false,single=false,soft=true,blockDelete=false,optionalStop=false,flood=false,mist=false,offline=false;
  double get wx=>mx-offsets[work]!['X']!; double get wy=>my-offsets[work]!['Y']!; double get wz=>mz-offsets[work]!['Z']!;
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{final p=await SharedPreferences.getInstance();if(mounted)setState((){ip=p.getString('ip')??ip;port=p.getString('port')??port;});}
  @override void dispose(){timer?.cancel();scroll.dispose();mdi.dispose();super.dispose();}
  void msg(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s,textAlign:TextAlign.center)));}
  void updateWork(){}
  void zero(String a){if(estop)return;setState((){offsets[work]![a]=a=='X'?mx:a=='Y'?my:mz;});}
  void zeroAll(){if(estop)return;setState((){offsets[work]!['X']=mx;offsets[work]!['Y']=my;offsets[work]!['Z']=mz;});}
  Future<void> pick()async{final r=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['nc','tap','gcode','txt','cnc'],withData:true);if(r==null||r.files.isEmpty)return;final f=r.files.first;if(f.bytes==null){msg('تعذرت قراءة الملف');return;}final c=String.fromCharCodes(f.bytes!);final l=c.split(RegExp(r'\r?\n'));final p=GCodeParser.parse(l);timer?.cancel();setState((){content=c;lines=l;parsed=p;fileName=f.name;fileInfo='${(f.size/1024).toStringAsFixed(1)} KB';line=0;done=0;mx=0;my=0;mz=0;feed=0;rpm=0;spindle=false;running=false;hold=false;});msg('تم تحميل الملف: ${p.moves.length} حركة XY');}
  void execute(int i){final p=parsed;if(p==null||i<0||i>=p.states.length)return;final s=p.states[i];setState((){mx=s.x;my=s.y;mz=s.z;feed=s.feed;rpm=s.rpm;spindle=s.spindle;done=p.moves.where((m)=>m.line<=i).length;});}
  void start(){if(estop){msg('ألغِ حالة الطوارئ التجريبية');return;}if(lines.isEmpty){msg('اختر ملف G-code');return;}if(running&&hold){setState(()=>hold=false);return;}if(line>=lines.length)setState((){line=0;done=0;mx=0;my=0;mz=0;});timer?.cancel();setState((){running=true;hold=false;});timer=Timer.periodic(const Duration(milliseconds:350),(t){if(!mounted||hold||estop)return;if(line>=lines.length){t.cancel();setState(()=>running=false);msg('انتهت المحاكاة');return;}execute(line);setState(()=>line++);if(scroll.hasClients)scroll.animateTo((line*22).clamp(0,scroll.position.maxScrollExtent),duration:const Duration(milliseconds:100),curve:Curves.easeOut);if(single)setState(()=>hold=true);});}
  void stop(){timer?.cancel();setState((){running=false;hold=false;line=0;done=0;spindle=false;});}
  void jog(String a,double d){if(estop||(running&&!hold)){msg('الحركة اليدوية غير متاحة');return;}final n=(double.tryParse(step)??1)*d;setState((){if(a=='X')mx+=n;if(a=='Y')my+=n;if(a=='Z')mz+=n;});}
  void runMdi(){final c=mdi.text.trim().toUpperCase();if(c.isEmpty||estop)return;final p=GCodeParser.parse([c]);final s=p.states.first;setState((){mx=s.x;my=s.y;mz=s.z;feed=s.feed;rpm=s.rpm;spindle=s.spindle;mdiStatus='تم تفسير الأمر محليًا: $c';});mdi.clear();}
  Future<void> connSettings()async{final a=TextEditingController(text:ip),b=TextEditingController(text:port);await showDialog(context:context,builder:(ctx)=>AlertDialog(title:const Text('إعداد الاتصال'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:a,decoration:const InputDecoration(labelText:'IP')),TextField(controller:b,decoration:const InputDecoration(labelText:'Port'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),ElevatedButton(onPressed:()async{final n=int.tryParse(b.text);if(a.text.trim().isEmpty||n==null||n<1||n>65535){msg('راجع IP وPort');return;}final p=await SharedPreferences.getInstance();await p.setString('ip',a.text.trim());await p.setString('port',b.text.trim());if(mounted)setState((){ip=a.text.trim();port=b.text.trim();});if(ctx.mounted)Navigator.pop(ctx);},child:const Text('حفظ'))]));a.dispose();b.dispose();}
  Widget box(String title,Widget child)=>Container(width:double.infinity,margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(12),border:Border.all(color:Colors.white12)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:green,fontWeight:FontWeight.bold)),const SizedBox(height:10),child]));
  Widget btn(String s,VoidCallback f,{Color color=const Color(0xFF344452)})=>SizedBox(width:double.infinity,height:45,child:ElevatedButton(onPressed:f,style:ElevatedButton.styleFrom(backgroundColor:color,foregroundColor:Colors.white),child:Text(s,textAlign:TextAlign.center)));
  Widget val(String s,double v)=>Expanded(child:Container(margin:const EdgeInsets.symmetric(horizontal:3),padding:const EdgeInsets.all(9),decoration:BoxDecoration(color:bg,borderRadius:BorderRadius.circular(8)),child:Column(children:[Text(s,style:const TextStyle(color:orange)),Text(v.toStringAsFixed(4),style:const TextStyle(color:green,fontFamily:'monospace'))])));
  Widget coords(String t,double x,double y,double z)=>box(t,Row(children:[val('X',x),val('Y',y),val('Z',z)]));
  Widget zeros()=>box('ZERO AXIS',Column(children:[Row(children:['X','Y','Z'].map((a)=>Expanded(child:Padding(padding:const EdgeInsets.all(3),child:btn('ZERO $a',()=>zero(a))))).toList()),btn('ZERO ALL',zeroAll,color:const Color(0xFF167A42))]));
  Widget program()=>ListView(padding:const EdgeInsets.all(12),children:[
    box('PROGRAM FILE',Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(fileName),Text(fileInfo),btn('LOAD G-CODE',pick)])),
    coords('WORK COORDINATES - $work',wx,wy,wz),
    box('PROGRAM RUN',Column(children:[Row(children:[Expanded(child:btn(hold?'RESUME':'CYCLE START',start,color:const Color(0xFF167A42))),const SizedBox(width:6),Expanded(child:btn('FEED HOLD',()=>setState(()=>hold=true),color:const Color(0xFF96701F)))]),btn('STOP',stop,color:Colors.red.shade900),LinearProgressIndicator(value:lines.isEmpty?0:line/lines.length),Text('Line $line / ${lines.length}') ])),
    box('FEED RATE',Column(children:[Text('F ${feed.toStringAsFixed(2)} | Actual ${(feed*fro/100).toStringAsFixed(2)}'),Text('FRO ${fro.toInt()}%'),Slider(value:fro,min:10,max:150,onChanged:(v)=>setState(()=>fro=v))])),
    box('SPINDLE',Column(children:[Text('S ${rpm.toStringAsFixed(0)} RPM | Actual ${(spindle?rpm*sro/100:0).toStringAsFixed(0)}'),Row(children:[Expanded(child:btn('SPINDLE ON',()=>setState(()=>spindle=true))),Expanded(child:btn('SPINDLE OFF',()=>setState(()=>spindle=false))]),Text('Override ${sro.toInt()}%'),Slider(value:sro,min:50,max:150,onChanged:(v)=>setState(()=>sro=v))])),
    box('G-CODE LINES',SizedBox(height:230,child:lines.isEmpty?const Center(child:Text('لا يوجد ملف')):ListView.builder(controller:scroll,itemCount:lines.length,itemExtent:22,itemBuilder:(c,i)=>Container(color:i==line-1?green.withOpacity(.2):null,child:Text('${i+1}: ${lines[i]}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontFamily:'monospace')))))),
  ]);
  Widget mdiPage()=>ListView(padding:const EdgeInsets.all(12),children:[coords('MACHINE COORDINATES',mx,my,mz),coords('WORK COORDINATES',wx,wy,wz),box('MDI INPUT',Column(children:[TextField(controller:mdi,decoration:const InputDecoration(hintText:'G0 X10 Y20 Z5',border:OutlineInputBorder()),onSubmitted:(_)=>runMdi()),btn('EXECUTE',runMdi,color:const Color(0xFF167A42)),Text(mdiStatus)])),box('QUICK COMMANDS',Wrap(spacing:5,children:['G90','G91','G20','G21','M3','M5','G54','G0 X0 Y0 Z0'].map((s)=>ActionChip(label:Text(s),onPressed:(){mdi.text=s;runMdi();})).toList()))]);
  Widget toolpath()=>ListView(padding:const EdgeInsets.all(12),children:[coords('MACHINE COORDINATES',mx,my,mz),box('PROGRAM LIMITS',Text('X ${parsed?.minX.toStringAsFixed(4)??"0"} to ${parsed?.maxX.toStringAsFixed(4)??"0"} | Y ${parsed?.minY.toStringAsFixed(4)??"0"} to ${parsed?.maxY.toStringAsFixed(4)??"0"}')),box('TOOLPATH DISPLAY',SizedBox(height:340,child:CustomPaint(painter:PathPainter(parsed,done,Offset(mx,my)),child:parsed==null?const Center(child:Text('حمّل ملف G-code')):null))),box('TOOLPATH CONTROL',Column(children:[btn('REGENERATE TOOLPATH',()=>setState(()=>parsed=GCodeParser.parse(lines))),btn('SIMULATE RUN',start),btn('RUN FROM HERE',()=>start()),btn('REWIND',stop),SwitchListTile(title:const Text('Single Block'),value:single,onChanged:(v)=>setState(()=>single=v))]))]);
  Widget jogPage()=>ListView(padding:const EdgeInsets.all(12),children:[coords('MACHINE COORDINATES',mx,my,mz),coords('WORK COORDINATES',wx,wy,wz),box('JOG STEP',DropdownButtonFormField(value:step,items:['0.001','0.01','0.1','1.0','10.0'].map((s)=>DropdownMenuItem(value:s,child:Text('$s mm'))).toList(),onChanged:(v)=>setState(()=>step=v??step))),box('JOG CONTROL',Column(children:['X','Y','Z'].map((a)=>Row(children:[Expanded(child:Text(a)),Expanded(child:btn('−',()=>jog(a,-1))),Expanded(child:btn('+',()=>jog(a,1)))])).toList())),box('JOG SPEED',Column(children:[Text('${jogSpeed.toInt()}%'),Slider(value:jogSpeed,min:1,max:100,onChanged:(v)=>setState(()=>jogSpeed=v))])),zeros()]);
  Widget offsetsPage()=>ListView(padding:const EdgeInsets.all(12),children:[coords('MACHINE COORDINATES',mx,my,mz),coords('WORK COORDINATES',wx,wy,wz),box('WORK OFFSET',DropdownButtonFormField(value:work,items:offsets.keys.map((s)=>DropdownMenuItem(value:s,child:Text(s))).toList(),onChanged:(v)=>setState(()=>work=v??work))),box('OFFSET VALUES',Row(children:[val('X',offsets[work]!['X']!),val('Y',offsets[work]!['Y']!),val('Z',offsets[work]!['Z']!)])),zeros(),box('TOOL OFFSET',btn('TOOL ZERO (SIMULATION)',()=>zero('Z')))]);
  Widget settingsPage()=>ListView(padding:const EdgeInsets.all(12),children:[box('GENERAL',Column(children:[SwitchListTile(title:const Text('Soft Limits (local simulation)'),value:soft,onChanged:(v)=>setState(()=>soft=v)),SwitchListTile(title:const Text('Offline'),value:offline,onChanged:(v)=>setState(()=>offline=v)),SwitchListTile(title:const Text('Block Delete'),value:blockDelete,onChanged:(v)=>setState(()=>blockDelete=v)),SwitchListTile(title:const Text('Optional Stop'),value:optionalStop,onChanged:(v)=>setState(()=>optionalStop=v)),SwitchListTile(title:const Text('Single Block'),value:single,onChanged:(v)=>setState(()=>single=v))])),box('COOLANT',Column(children:[SwitchListTile(title:const Text('Flood'),value:flood,onChanged:(v)=>setState(()=>flood=v)),SwitchListTile(title:const Text('Mist'),value:mist,onChanged:(v)=>setState(()=>mist=v))])),box('MACHINE CONFIGURATION',const Text('Port & Pins وMotor Tuning وHoming وSpindle Pulley تحتاج نقل إعدادات Mach3 الأصلية والتحقق منها. هذه الشاشة لا تغيّر إعدادات الكمبيوتر.'))]);
  Widget diagnostics()=>ListView(padding:const EdgeInsets.all(12),children:[coords('MACHINE POSITION',mx,my,mz),coords('WORK POSITION',wx,wy,wz),box('INPUT / OUTPUT STATUS (SIMULATED)',Column(children:signals.keys.map((k)=>SwitchListTile(title:Text(k),value:signals[k]!,onChanged:(v)=>setState(()=>signals[k]=v)).toList())),box('STATUS',Text('Program: ${running?(hold?"Feed Hold":"Running"):"Idle"}\nSpindle: ${spindle?"ON":"OFF"}\nEmergency: ${estop?"ACTIVE":"CLEAR"}\nConnection: ${connected?"SIMULATED":"NOT CONNECTED"}')),box('WARNING',const Text('هذه المؤشرات تجريبية وليست قراءة من لوحة Mach3. زر الطوارئ المادي المستقل ضروري.'))]);
  Widget files()=>ListView(padding:const EdgeInsets.all(12),children:[box('G-CODE FILE',Column(children:[Text(fileName),Text(fileInfo),btn('SELECT FILE',pick),btn('PREPARE FOR MACH3',()=>msg('الإرسال الحقيقي غير مربوط')),btn('OPEN PROGRAM RUN',()=>setState(()=>page=0))])),box('FILE CONTENT',SizedBox(height:350,child:SingleChildScrollView(child:SelectableText(content,style:const TextStyle(fontFamily:'monospace')))))]);
  Widget connection()=>ListView(padding:const EdgeInsets.all(12),children:[box('WINDOWS COMPUTER',Column(children:[Text('IP: $ip'),Text('Port: $port'),btn('EDIT SETTINGS',connSettings)])),box('CONNECTION',Column(children:[Text(connected?'اتصال تجريبي':'غير متصل'),btn(connected?'DISCONNECT':'CONNECT (SIMULATED)',()=>setState(()=>connected=!connected))])),box('PROTOCOL',const Text('WebSocket غير مربوط. يلزم برنامج وسيط على Windows للتواصل مع Mach3.'))]);
  Widget current()=>[program,mdiPage,toolpath,jogPage,offsetsPage,settingsPage,diagnostics,files,connection][page]();
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(names[page]),actions:[IconButton(onPressed:()=>setState(()=>estop=!estop),icon:Icon(estop?Icons.lock_open:Icons.warning,color:estop?green:red))]),body:SafeArea(child:current()),bottomNavigationBar:NavigationBar(selectedIndex:page,onDestinationSelected:(v)=>setState(()=>page=v),labelBehavior:NavigationDestinationLabelBehavior.alwaysShow,destinations:const[NavigationDestination(icon:Icon(Icons.play_arrow),label:'Run'),NavigationDestination(icon:Icon(Icons.keyboard),label:'MDI'),NavigationDestination(icon:Icon(Icons.route),label:'Path'),NavigationDestination(icon:Icon(Icons.gamepad),label:'Jog'),NavigationDestination(icon:Icon(Icons.tune),label:'Offsets'),NavigationDestination(icon:Icon(Icons.settings),label:'Settings'),NavigationDestination(icon:Icon(Icons.monitor_heart),label:'Diag'),NavigationDestination(icon:Icon(Icons.folder),label:'Files'),NavigationDestination(icon:Icon(Icons.wifi),label:'Connect')]));
}

class PathPainter extends CustomPainter {
  final ParsedProgram? data;final int done;final Offset position;
  PathPainter(this.data,this.done,this.position);
  @override void paint(Canvas c,Size s){
    final d=data;if(d==null||d.moves.isEmpty)return;
    final rx=math.max(.001,d.maxX-d.minX),ry=math.max(.001,d.maxY-d.minY);
    final scale=math.min((s.width-40)/rx,(s.height-40)/ry),w=rx*scale,h=ry*scale,l=(s.width-w)/2,t=(s.height-h)/2;
    Offset cv(Offset p)=>Offset(l+(p.dx-d.minX)*scale,s.height-t-(p.dy-d.minY)*scale);
    c.drawRect(Rect.fromLTWH(l,t,w,h),Paint()..color=Colors.white24..style=PaintingStyle.stroke);
    for(var i=0;i<d.moves.length;i++){final m=d.moves[i],path=Path()..moveTo(cv(m.points.first).dx,cv(m.points.first).dy);for(final p in m.points.skip(1)){final q=cv(p);path.lineTo(q.dx,q.dy);}c.drawPath(path,Paint()..color=i<done?green:m.rapid?Colors.blueAccent:Colors.white54..style=PaintingStyle.stroke..strokeWidth=2);}
    c.drawCircle(cv(position),6,Paint()..color=orange);
  }
  @override bool shouldRepaint(covariant PathPainter old)=>old.data!=data||old.done!=done||old.position!=position;
}