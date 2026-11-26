#!/usr/bin/env python3
"""FolderBridge: three-way synchronization, SSH transport and immutable recovery."""
import uuid
import inspect
import argparse,base64,posixpath,contextlib,datetime,fcntl,hashlib,json,os,secrets,shlex,shutil,stat,subprocess,sys,tempfile,time,unicodedata
from pathlib import Path

VERSION='2.2.0'
CHUNK=1024*1024
class BridgeError(Exception):pass
def digest(data):return hashlib.sha256(data).hexdigest()
def file_digest(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for block in iter(lambda:f.read(CHUNK),b''):h.update(block)
 return h.hexdigest()
def encode(value):return base64.urlsafe_b64encode(json.dumps(value).encode()).decode()
def signature(item):
 if item is None:return None
 return (item['type'],item.get('hash',''))
def atomic_json(path,value):
 path.parent.mkdir(parents=True,exist_ok=True)
 tmp=path.with_name(path.name+'.'+secrets.token_hex(4)+'.tmp')
 with open(tmp,'w') as f:json.dump(value,f,ensure_ascii=False);f.flush();os.fsync(f.fileno())
 os.chmod(tmp,0o600);os.replace(tmp,path)
def identity(spec):
 fields={k:spec.get(k) for k in ['kind','host','port','root']}
 if spec.get('kind')=='baidu' and spec.get('profileID'):fields['profileID']=str(uuid.UUID(spec['profileID'])).upper()
 return digest(json.dumps(fields,sort_keys=True).encode())[:24]
def stamp():return datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')+'-'+secrets.token_hex(4)

def lock_tree(storage, root):
 root = Path(root)
 storage.mkdir(parents=True, exist_ok=True)
 stack = contextlib.ExitStack()
 try:
  for path in [*reversed(root.parents), root]:
   key = digest(unicodedata.normalize('NFC', str(path)).casefold().encode())
   handle = stack.enter_context(open(storage/key, 'a+'))
   mode = fcntl.LOCK_EX if path == root else fcntl.LOCK_SH
   fcntl.flock(handle, mode | fcntl.LOCK_NB)
  return stack
 except BlockingIOError:
  stack.close()
  raise BridgeError('此目录或其子目录正在同步，请稍后重试。')
 except BaseException:
  stack.close()
  raise

class Agent:
 def __init__(self,root,storage):
  root=Path(root).expanduser()
  if not root.is_absolute() or str(root.resolve())=='/':raise BridgeError('请选择具体文件夹，不能同步整个文件系统。')
  self.tree_lock=lock_tree(Path(storage).expanduser()/'.locks', root.resolve())
  root.mkdir(parents=True,exist_ok=True)
  if root.is_symlink():raise BridgeError('同步根目录不能是符号链接。')
  self.root=root.resolve();self.store=Path(storage).expanduser()/digest(str(self.root).encode())[:24]
  if self.store==self.root or self.root in self.store.parents:raise BridgeError('恢复区必须位于同步文件夹之外。')
  self.store.mkdir(parents=True,exist_ok=True);os.chmod(self.store,0o700)
  self.lock=open(self.store/'lock','a+')
  try:fcntl.flock(self.lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:raise BridgeError('此文件夹正在被另一个同步任务使用。')
  self.cache_path=self.store/'hash-cache.json'
  try:self.cache=json.loads(self.cache_path.read_text())
  except (FileNotFoundError,ValueError):self.cache={}
  self.pending={}
 def close(self):
  for item in self.pending.values():
   try:Path(item['tmp']).unlink(missing_ok=True)
   except OSError:pass
  self.pending.clear();self.lock.close();self.tree_lock.close()
 def path(self,relative):
  p=Path(relative)
  if p.is_absolute() or '..' in p.parts or not relative or relative.startswith('.folderbridge-tmp-'):raise BridgeError('文件路径无效。')
  target=self.root/p
  parent=target.parent
  if parent.resolve()!=self.root and self.root not in parent.resolve().parents:raise BridgeError('拒绝访问同步目录之外的路径。')
  cursor=self.root
  for part in p.parts[:-1]:
   cursor=cursor/part
   if cursor.is_symlink():raise BridgeError('不能穿过符号链接写入文件。')
  return target
 def entry(self,p,relative):
  s=p.lstat();mode=stat.S_IMODE(s.st_mode)&0o777
  if stat.S_ISLNK(s.st_mode):
   target=os.readlink(p);return {'type':'link','hash':digest(target.encode()),'target':target,'size':0,'mode':mode,'mtime':s.st_mtime}
  if stat.S_ISDIR(s.st_mode):return {'type':'dir','hash':'','size':0,'mode':mode,'mtime':s.st_mtime}
  if not stat.S_ISREG(s.st_mode):raise BridgeError('不支持设备或套接字文件：'+relative)
  token=[s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_ino]
  cached=self.cache.get(relative)
  if cached and cached['token']==token:h=cached['hash']
  else:
   h=hashlib.sha256()
   with open(p,'rb') as f:
    for block in iter(lambda:f.read(CHUNK),b''):h.update(block)
   after=p.lstat()
   if [after.st_size,after.st_mtime_ns,after.st_ctime_ns,after.st_ino]!=token:raise BridgeError('文件正在修改，请稍后重试：'+relative)
   h=h.hexdigest();self.cache[relative]={'token':token,'hash':h}
  return {'type':'file','hash':h,'size':s.st_size,'mode':mode,'mtime':s.st_mtime}
 def scan(self):
  result={}
  def walk(directory,prefix=''):
   for child in sorted(os.scandir(directory),key=lambda x:x.name):
    if child.name.startswith('.folderbridge-tmp-'):continue
    rel=prefix+child.name;item=self.entry(Path(child.path),rel);result[rel]=item
    if item['type']=='dir':walk(child.path,rel+'/')
  walk(self.root);atomic_json(self.cache_path,self.cache);return result
 def list(self,relative=None):
  directory=self.path(relative) if relative else self.root
  if directory.is_symlink() or not directory.is_dir():raise BridgeError('目录已变更，请重试。')
  rows=[]
  for child in sorted(os.scandir(directory),key=lambda x:(not x.is_dir(follow_symlinks=False),x.name.casefold())):
   if child.name.startswith('.folderbridge-tmp-'):continue
   s=child.stat(follow_symlinks=False)
   rows.append({'name':child.name,'path':child.name,'size':s.st_size,'isDirectory':child.is_dir(follow_symlinks=False),'isSymbolicLink':child.is_symlink(),'modified':s.st_mtime})
  return rows
 def capabilities(self):
  fd,name=tempfile.mkstemp(prefix='.folderbridge-tmp-case-',dir=self.root);os.close(fd)
  try:return {'caseSensitive':not Path(name.upper()).exists()}
  finally:Path(name).unlink()
 def current(self,relative):
  p=self.path(relative)
  return self.entry(p,relative) if p.exists() or p.is_symlink() else None
 def check(self,relative,expected):
  actual=self.current(relative)
  if signature(actual)!=signature(expected):raise BridgeError('扫描后文件发生了变化，已停止：'+relative)
 def blob(self,h):
  if len(h)!=64 or any(c not in '0123456789abcdef' for c in h):raise BridgeError('快照内容校验失败。')
  return self.store/'objects'/h[:2]/h
 def checkpoint(self,tx,phase,entries):
  actual=self.scan()
  if {p:signature(v) for p,v in actual.items()}!={p:signature(v) for p,v in entries.items()}:raise BridgeError('生成快照时目录发生变化，已停止。')
  for rel,item in entries.items():
   if item['type']!='file':continue
   dest=self.blob(item['hash'])
   if dest.exists():continue
   dest.parent.mkdir(parents=True,exist_ok=True);tmp=dest.with_name(dest.name+'.tmp-'+secrets.token_hex(4))
   shutil.copyfile(self.path(rel),tmp)
   if file_digest(tmp)!=item['hash']:tmp.unlink();raise BridgeError('文件在备份时被修改：'+rel)
   os.chmod(tmp,0o400);os.replace(tmp,dest)
  directory=self.store/'snapshots'/tx
  atomic_json(directory/(phase+'.json'),{'id':tx,'phase':phase,'root':str(self.root),'created':time.time(),'entries':entries})
  return str(directory)
 def archive(self,relative,tx,category,move=False):
  source=self.path(relative)
  if not source.exists() and not source.is_symlink():return
  dest=self.store/'snapshots'/tx/category/relative
  dest.parent.mkdir(parents=True,exist_ok=True)
  if dest.exists() or dest.is_symlink():
   if source.is_dir() and not source.is_symlink() and dest.is_dir():
    if any(source.iterdir()):raise BridgeError('目录内容发生变化，已停止删除：'+relative)
    if move:source.rmdir()
    return
   raise BridgeError('恢复区已有同名文件，已停止。')
  if source.is_dir() and not source.is_symlink():
   if any(source.iterdir()):raise BridgeError('目录内容发生变化，已停止删除：'+relative)
   dest.mkdir();
   if move:source.rmdir()
  elif move:os.replace(source,dest)
  elif source.is_symlink():os.symlink(os.readlink(source),dest)
  else:shutil.copy2(source,dest)
 def remove(self,relative,expected,tx):
  self.check(relative,expected);self.archive(relative,tx,'deleted',True)
 def mkdir(self,relative,expected,tx):
  p=self.path(relative);self.check(relative,expected)
  if expected and expected['type']=='dir':return
  if expected:self.archive(relative,tx,'overwritten',True)
  p.mkdir(parents=True,exist_ok=True)
 def begin(self,relative,item,expected,tx):
  self.check(relative,expected);p=self.path(relative);p.parent.mkdir(parents=True,exist_ok=True)
  token=secrets.token_hex(12);tmp=p.with_name('.folderbridge-tmp-'+token)
  if item['type']=='link':os.symlink(item['target'],tmp)
  else:
   fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.close(fd)
  self.pending[token]={'tmp':str(tmp),'relative':relative,'item':item,'expected':expected,'tx':tx}
  return token
 def chunk(self,token,data):
  with open(self.pending[token]['tmp'],'ab') as f:f.write(base64.b64decode(data,validate=True))
 def finish(self,token):
  job=self.pending[token];p=self.path(job['relative']);tmp=Path(job['tmp']);item=job['item']
  if item['type']=='file':
   h=hashlib.sha256()
   with open(tmp,'rb') as f:
    for b in iter(lambda:f.read(CHUNK),b''):h.update(b)
   if h.hexdigest()!=item['hash']:raise BridgeError('传输内容校验失败：'+job['relative'])
  self.check(job['relative'],job['expected'])
  if job['expected']:
   isdir=job['expected']['type']=='dir'
   self.archive(job['relative'],job['tx'],'overwritten',isdir)
  if item['type']=='file':
   os.chmod(tmp,item.get('mode',0o644)&0o777)
   if os.geteuid()==0:
    owner=p.parent.stat();os.chown(tmp,owner.st_uid,owner.st_gid)
   with open(tmp,'rb') as f:os.fsync(f.fileno())
  os.replace(tmp,p);self.pending.pop(token)
 def read(self,relative,offset):
  with open(self.path(relative),'rb') as f:f.seek(offset);return base64.b64encode(f.read(CHUNK)).decode()
 def read_blob(self,h,offset):
  with open(self.blob(h),'rb') as f:f.seek(offset);return base64.b64encode(f.read(CHUNK)).decode()
 def snapshot(self,tx,phase):
  if '/' in tx or phase not in ['before','after']:raise BridgeError('快照无效。')
  return json.loads((self.store/'snapshots'/tx/(phase+'.json')).read_text())
 def call(self,op,**kw):return getattr(self,op)(**kw)

def ssh_arguments(spec):
  host=spec.get('host','');port=int(spec.get('port',22))
  if not host or host.startswith('-') or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@:-[]' for c in host):raise BridgeError('SSH 主机格式不正确。')
  if port<1 or port>65535:raise BridgeError('SSH 端口无效。')
  args=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=12','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-p',str(port)]
  key=spec.get('identityFile','')
  if key:args+=['-i',str(Path(key).expanduser())]
  args+=[host]
  return args

class SSHAgent:
 def __init__(self,spec,source):
  args=ssh_arguments(spec)
  install='umask 077; mkdir -p "$HOME/.local/lib/folderbridge"; t=$(mktemp "$HOME/.local/lib/folderbridge/engine.XXXXXX"); cat > "$t" && chmod 700 "$t" && mv "$t" "$HOME/.local/lib/folderbridge/engine.py"'
  r=subprocess.run(args+[install],input=source,capture_output=True,timeout=40)
  if r.returncode:raise BridgeError(r.stderr.decode(errors='replace').strip() or 'SSH 连接失败。')
  command='python3 "$HOME/.local/lib/folderbridge/engine.py" agent --spec '+shlex.quote(encode(spec))
  self.err=tempfile.TemporaryFile()
  self.proc=subprocess.Popen(args+[command],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.err,text=True,bufsize=1)
  hello=self.proc.stdout.readline()
  if not hello:
   self.err.seek(0);raise BridgeError(self.err.read().decode(errors='replace') or '远端代理启动失败，请确认 Python 3 已安装。')
  packet=json.loads(hello)
  if not packet.get('ok'):raise BridgeError(packet.get('error','SSH 连接失败。'))
 def call(self,op,**kw):
  self.proc.stdin.write(json.dumps({'op':op,'args':kw},ensure_ascii=False)+'\n');self.proc.stdin.flush()
  line=self.proc.stdout.readline()
  if not line:raise BridgeError('SSH 连接中断；同步基线未更新，已有快照仍可恢复。')
  reply=json.loads(line)
  if not reply.get('ok'):raise BridgeError(reply.get('error','远程操作失败。'))
  return reply.get('value')
 def close(self):
  try:self.proc.stdin.close();self.proc.wait(timeout=5)
  except Exception:self.proc.terminate()
  self.err.close()

class CloudAgent:
 """Baidu uses a durable local content cache; remote removals are moved to recovery."""
 def __init__(self,spec,state,source,materialize=True):
  self.spec=spec;self.base=spec.get('root','').strip('/')
  if '..' in self.base.split('/') or '~' in self.base.split('/'):raise BridgeError('百度网盘目录无效。')
  self.binary=spec.get('bdpan')
  if not self.binary or not Path(self.binary).is_file():raise BridgeError('没有找到百度网盘连接工具。')
  self.state=state;self.cache=state/'cloud-cache'/identity(spec);self.cache.mkdir(parents=True,exist_ok=True)
  self.live=self.cache/'live';self.live.mkdir(exist_ok=True);self.original={};self.session=spec.get('sessionID') or str(int(time.time()))+'-'+secrets.token_hex(3)
  self.profile=str(uuid.UUID(spec['profileID'])).upper() if spec.get('profileID') else None
  self.agent=None
  self.tree_lock=None
  if materialize:
   locks=state/'cloud-locks' if not self.profile else state/'baidu-accounts'/self.profile/'locks'
   self.tree_lock=lock_tree(locks, Path('/')/self.base)
   try:self.prepare();self.agent=Agent(self.live,state/'recovery')
   except BaseException:self.tree_lock.close();raise
 def bd(self,op,*args):
  cmd=[self.binary,op,*args,'--json','--no-check-update','--agentname','FolderBridge-macOS','--session-id',self.session]
  if self.profile:
   directory=self.state/'baidu-accounts'/self.profile
   directory.mkdir(mode=0o700,parents=True,exist_ok=True)
   cmd+=['--config-path',str(directory/'config.json')]
  if self.spec.get('sessionInput'):cmd+=['--session-input',self.spec['sessionInput']]
  r=subprocess.run(cmd,capture_output=True,timeout=600)
  if r.returncode:raise BridgeError((r.stderr or r.stdout).decode(errors='replace').strip())
  try:return json.loads(r.stdout)
  except ValueError:raise BridgeError('百度网盘返回内容无法解析。')
 def remote(self,rel):return '/'.join(x for x in [self.base,rel] if x)
 def mkdir(self,path):
  parts=path.strip('/').split('/') if path else []
  for i in range(1,len(parts)+1):
   p='/'.join(parts[:i])
   try:self.bd('mkdir',p)
   except BridgeError as e:
    if not any(x in str(e).lower() for x in ['exist','已存在','31061','-8']):raise
 def rows(self,path):
  rows=self.bd('ls',*([path] if path else []))
  if isinstance(rows,dict):rows=rows.get('items',[])
  if not isinstance(rows,list):raise BridgeError('百度网盘列表格式无效。')
  return rows
 def inventory(self):
  result={}
  def walk(path,prefix=''):
   for row in self.rows(path):
    name=row.get('server_filename','')
    if not name or name=='_FolderBridgeHistory':continue
    if str(row.get('path','')).rstrip('/')==('/apps/bdpan/'+path).rstrip('/'):continue
    rel=prefix+name
    isdir=bool(row.get('isdir',False));result[rel]={'row':row,'type':'dir' if isdir else 'file'}
    if isdir:walk('/'.join(x for x in [path,name] if x),rel+'/')
  walk(self.base);return result
 def prepare(self):
  self.original=self.inventory()
  aliases={}
  for rel in self.original:
   key=unicodedata.normalize('NFC',rel).casefold()
   if key in aliases and aliases[key]!=rel:raise BridgeError('百度网盘包含本机无法同时保存的同名路径：'+aliases[key]+' / '+rel)
   aliases[key]=rel
  try:old=json.loads((self.cache/'metadata.json').read_text())
  except (FileNotFoundError,ValueError):old={}
  # Cache is private staging, never a user's selected source directory.
  for p in sorted(self.live.rglob('*'),key=lambda p:len(p.parts),reverse=True):
   rel=str(p.relative_to(self.live))
   if rel not in self.original:
    if p.is_dir():p.rmdir()
    else:p.unlink()
  for rel,item in sorted(self.original.items(),key=lambda x:len(Path(x[0]).parts)):
   p=self.live/rel
   if item['type']=='dir':
    if p.is_file():p.unlink()
    p.mkdir(parents=True,exist_ok=True);continue
   row=item['row'];token=[row.get('fsid',row.get('fs_id')),row.get('size'),row.get('server_mtime'),row.get('md5')]
   if old.get(rel)==token and p.is_file():continue
   if p.is_dir():shutil.rmtree(p)
   p.parent.mkdir(parents=True,exist_ok=True)
   tmp=p.with_name('.folderbridge-tmp-'+secrets.token_hex(6))
   self.bd('download',self.remote(rel),str(tmp));os.replace(tmp,p);old[rel]=token
  atomic_json(self.cache/'metadata.json',{k:v for k,v in old.items() if k in self.original})
 def call(self,op,**kw):
  if op=='list' and self.agent is None:
   return [{'name':r.get('server_filename',''),'path':r.get('server_filename',''),'size':int(r.get('size',0)),'isDirectory':bool(r.get('isdir',False)),'modified':None} for r in self.rows(self.base) if r.get('server_filename') and str(r.get('path','')).rstrip('/')!=('/apps/bdpan/'+self.base).rstrip('/')]
  return self.agent.call(op,**kw)
 def commit(self,tx):
  current=self.inventory()
  def tokens(tree):return {p:[v['type'],v['row'].get('fsid',v['row'].get('fs_id')),v['row'].get('size'),v['row'].get('server_mtime'),v['row'].get('md5')] for p,v in tree.items()}
  if tokens(current)!=tokens(self.original):raise BridgeError('同步期间百度网盘内容发生变化，已停止写入。本地快照可恢复。')
  desired=self.agent.scan();before=self.before
  changes=[p for p in set(before)|set(desired) if signature(before.get(p))!=signature(desired.get(p))]
  removals=[p for p in changes if p in before]
  roots=[p for p in removals if not any(str(parent) in removals and before[str(parent)]['type']=='dir' for parent in Path(p).parents if str(parent)!='.')]
  for rel in sorted(roots,key=lambda x:len(Path(x).parts),reverse=True):
   if rel not in before:continue
   history='_FolderBridgeHistory/'+identity(self.spec)+'/'+tx+'/deleted/'+str(Path(rel).parent)
   self.mkdir(history);self.bd('mv',self.remote(rel),history)
  for rel in sorted(changes,key=lambda x:len(Path(x).parts)):
   item=desired.get(rel)
   if item is None:continue
   if item['type']=='dir':self.mkdir(self.remote(rel))
   else:
    parent=str(Path(self.remote(rel)).parent);self.mkdir('' if parent=='.' else parent);self.bd('upload',str(self.live/rel),self.remote(rel))
  # Read back changed remote contents before declaring the two sides identical.
  self.prepare()
 def close(self):
  if self.agent:self.agent.close()
  if self.tree_lock:self.tree_lock.close()

def endpoint(spec,state,source):
 if spec['kind']=='local':return Agent(spec['root'],state/'recovery')
 if spec['kind']=='ssh':return SSHAgent(spec,source)
 if spec['kind']=='baidu':return CloudAgent(spec,state,source)
 raise BridgeError('未知的连接类型。')

def pair_id(left,right):return digest(json.dumps([identity(left),identity(right)]).encode())[:24]
def plan(left,right,base,preferred=None):
 actions=[];conflicts=[]
 for p in sorted(set(left)|set(right)|set(base)):
  l,r,b=left.get(p),right.get(p),base.get(p);ls,rs,bs=signature(l),signature(r),signature(b)
  if ls==rs:continue
  if ls==bs:source='right'
  elif rs==bs:source='left'
  elif preferred:source=preferred
  else:conflicts.append({'path':p,'left':l,'right':r,'base':b});continue
  actions.append({'path':p,'source':source,'item':l if source=='left' else r,'expected':r if source=='left' else l})
 return actions,conflicts

def transfer(source,target,rel,item,expected,tx,blob=False):
 token=target.call('begin',relative=rel,item=item,expected=expected,tx=tx)
 if item['type']=='file':
  offset=0
  while True:
   data=source.call('read_blob',h=item['hash'],offset=offset) if blob else source.call('read',relative=rel,offset=offset)
   if not data:break
   target.call('chunk',token=token,data=data);offset+=len(base64.b64decode(data))
 target.call('finish',token=token)

def upload_candidates(list_directory):
 rows=[]
 def visit(relative=None):
  for row in list_directory(relative):
   name=row['name']
   if name.startswith('.') or row['isSymbolicLink']:continue
   path=str(Path(relative or '')/name)
   rows.append({'path':path,'size':row['size'],'directory':row['isDirectory']})
   if row['isDirectory']:visit(path)
 visit()
 return rows

def missing_uploads(rows, list_directory):
 directories=[]
 files=[]
 absent=set()
 listings={}
 for row in rows:
  path=Path(row['path'])
  parent=str(path.parent)
  if parent in absent:existing=None
  else:
   if parent not in listings:
    listings[parent]={item['name']:item['isDirectory'] for item in list_directory(None if parent=='.' else parent)}
   existing=listings[parent].get(path.name)
  if existing is None:
   if row['directory']:
    directories.append(str(path))
    absent.add(str(path))
   else:files.append({'path':str(path),'size':row['size']})
  elif row['directory'] and not existing:raise ValueError('远端同名项不是目录：'+str(path))
 return {'directories':directories,'files':files,'checked':sum(not row['directory'] for row in rows)}

def upload_missing(source, target):
 tx=stamp()
 rows=upload_candidates(lambda rel:source.call('list',relative=rel))
 plan=missing_uploads(rows,lambda rel:target.call('list',relative=rel))
 for path in plan['directories']:target.call('mkdir',relative=path,expected=None,tx=tx)
 for row in plan['files']:
  path=row['path']
  item=source.call('current',relative=path)
  if not item or item['type']!='file':raise BridgeError('源文件已变更：'+path)
  transfer(source,target,path,item,None,tx)
 return len(plan['directories'])+len(plan['files'])

def readonly_listing(root, relative):
 path=Path(root)
 if not path.is_absolute() or path.resolve()==Path('/'):raise ValueError('请选择具体文件夹。')
 if path.is_symlink():raise ValueError('同步根目录不能是符号链接。')
 if relative:
  for part in Path(relative).parts:
   if part in ('..','/'):raise ValueError('无效路径。')
   path=path/part
   if path.is_symlink():raise ValueError('目录已变更，请重新检查。')
 try:
  with os.scandir(path) as entries:
   return [{'name':e.name,'size':e.stat(follow_symlinks=False).st_size,
            'isDirectory':e.is_dir(follow_symlinks=False),'isSymbolicLink':e.is_symlink()} for e in entries]
 except FileNotFoundError:
  if not relative:return []
  raise

def preview_upload(local,remote):
 if local['kind']!='local' or remote['kind'] not in ('local','ssh'):raise BridgeError('单向检查需要本机和目标文件夹。')
 if not Path(local['root']).is_dir():raise BridgeError('找不到本机文件夹。')
 rows=upload_candidates(lambda rel:readonly_listing(local['root'],rel))
 if remote['kind']=='ssh':
  script='import json,os,sys\nfrom pathlib import Path\n'+inspect.getsource(readonly_listing)+inspect.getsource(missing_uploads)
  script+="root,rows=json.load(sys.stdin)\nprint(json.dumps(missing_uploads(rows,lambda rel:readonly_listing(root,rel))))"
  proc=subprocess.run(ssh_arguments(remote)+['python3 -c '+shlex.quote(script)],text=True,
                      input=json.dumps([remote['root'],rows]),capture_output=True,timeout=180)
  if proc.returncode:raise BridgeError(proc.stderr.strip() or '远端检查失败。')
  plan=json.loads(proc.stdout)
 else:plan=missing_uploads(rows,lambda rel:readonly_listing(remote['root'],rel))
 return {'status':'ok','checked':plan['checked'],'files':sorted(plan['files'],key=lambda row:row['path'])}

def apply(actions,left,right,tx,restore_source=None):
 for a in sorted([x for x in actions if x['item'] is None],key=lambda x:len(Path(x['path']).parts),reverse=True):
  target=right if a['source']=='left' else left;target.call('remove',relative=a['path'],expected=a['expected'],tx=tx)
 for a in sorted([x for x in actions if x['item'] and x['item']['type']=='dir'],key=lambda x:len(Path(x['path']).parts)):
  target=right if a['source']=='left' else left;target.call('mkdir',relative=a['path'],expected=a['expected'],tx=tx)
 for a in [x for x in actions if x['item'] and x['item']['type']!='dir']:
  source,target=(left,right) if a['source']=='left' else (right,left)
  transfer(restore_source or source,target,a['path'],a['item'],a['expected'],tx,blob=restore_source is not None)

# Executed locally or over SSH. Listing never creates a folder or takes a writer lock.
BROWSE_SCRIPT = """
import json, os, sys
path = json.load(sys.stdin)
with os.scandir(path) as entries:
 rows = []
 for entry in entries:
  if entry.name.startswith(".folderbridge-tmp-"):continue
  try:metadata = entry.stat(follow_symlinks=False)
  except FileNotFoundError:continue
  rows.append({"name":entry.name,"path":entry.name,"size":metadata.st_size,
               "modified":metadata.st_mtime,"isDirectory":entry.is_dir(follow_symlinks=False)})
print(json.dumps(rows))
"""

def browse(spec, state):
 if spec['kind']=='baidu':
  client=CloudAgent(spec,state,b'',materialize=False)
  try:items=client.call('list')
  finally:client.close()
 else:
  if spec['kind']=='local':args=[sys.executable,'-c',BROWSE_SCRIPT]
  elif spec['kind']=='ssh':args=ssh_arguments(spec)+['python3 -c '+shlex.quote(BROWSE_SCRIPT)]
  else:raise BridgeError('未知连接类型。')
  proc=subprocess.run(args,input=json.dumps(spec['root']),text=True,capture_output=True,timeout=45)
  if proc.returncode:raise BridgeError(proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else '无法读取目录。')
  items=json.loads(proc.stdout)
 return sorted(items,key=lambda item:(not item['isDirectory'],item['name'].casefold()))

def main_request(req,state):
 state.mkdir(parents=True,exist_ok=True);os.chmod(state,0o700);source=Path(__file__).read_bytes()
 if req['op']=='previewUpload':return preview_upload(req['left'],req['right'])
 if req['op']=='list':
  return {'status':'ok','items':browse(req['endpoint'],state)}
 leftspec,rightspec=req['left'],req['right'];pair=pair_id(leftspec,rightspec)
 if identity(leftspec)==identity(rightspec):raise BridgeError('请选择两个不同的文件夹。')
 if leftspec['kind']==rightspec['kind']:
  kind=leftspec['kind']
  same=kind in ['local','baidu'] or (kind=='ssh' and leftspec.get('host')==rightspec.get('host') and leftspec.get('port',22)==rightspec.get('port',22))
  if same:
   roots=[str(Path(s['root']).resolve()) if kind=='local' else posixpath.normpath('/'+s['root'].lstrip('/')) for s in [leftspec,rightspec]]
   a,b=roots
   if a==b or b.startswith(a.rstrip('/')+'/') or a.startswith(b.rstrip('/')+'/'):raise BridgeError('两个同步目录不能相同或相互包含。')
 directory=state/'pairs'/pair;directory.mkdir(parents=True,exist_ok=True)
 if req['op']=='snapshots':
  rows=[]
  for p in sorted(directory.glob('*.snapshot.json'),reverse=True):
   d=json.loads(p.read_text());rows.append({k:d[k] for k in ['id','created','reason','leftRoot','rightRoot']})
  rows.sort(key=lambda row:row['created'],reverse=True)
  return {'status':'ok','snapshots':rows}
 cloud = any(s['kind']=='baidu' for s in (leftspec,rightspec))
 direction = req.get('direction', 'upload' if cloud else 'bidirectional')
 if direction not in ('upload','bidirectional') or req['op'] not in ('sync','restore'):
  raise BridgeError('同步请求无效。')
 if direction=='upload' and (req['op']!='sync' or leftspec['kind']!='local' or cloud):
  raise BridgeError('单向上传只从本机发起；百度网盘使用原有的增量上传引擎。')
 generation = req.get('baselineGeneration') or ''
 lock=open(directory/'lock','a+')
 try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:raise BridgeError('此同步对正在运行。')
 left=right=None
 try:
  left=endpoint(leftspec,state,source);right=endpoint(rightspec,state,source)
  if direction=='upload':
   return {'status':'ok','operations':upload_missing(left,right)}
  l,r=left.call('scan'),right.call('scan')
  for ep in [left,right]:
   if not ep.call('capabilities')['caseSensitive']:
    aliases={}
    for p in set(l)|set(r):
     key=unicodedata.normalize('NFC',p).casefold()
     if key in aliases and aliases[key]!=p:raise BridgeError('目标文件系统存在大小写或 Unicode 文件名冲突：'+aliases[key]+' / '+p)
     aliases[key]=p
  if isinstance(left,CloudAgent):left.before=l
  if isinstance(right,CloudAgent):right.before=r
  try:
   previous=json.loads((directory/'baseline.json').read_text())
   base=previous['entries'] if (previous.get('generation') or '')==generation else {}
  except (FileNotFoundError,ValueError):base={}
  token=digest(json.dumps([l,r,base],sort_keys=True).encode())
  if req.get('conflictToken') and req['conflictToken']!=token:raise BridgeError('确认冲突后文件又发生变化，请重新同步并检查。')
  restoring=req['op']=='restore'
  if restoring:
   meta=json.loads((directory/(req['snapshot']+'.snapshot.json')).read_text())
   restore_source=left if meta.get('side',req.get('side','left'))=='left' else right
   desired=restore_source.call('snapshot',tx=meta.get('snapshotTx',meta['id']),phase=meta.get('phase','after'))['entries']
   actions=[]
   for side,tree in [('left',l),('right',r)]:
    for p in sorted(set(desired)|set(tree)):
     if signature(desired.get(p))!=signature(tree.get(p)):actions.append({'path':p,'source':'right' if side=='left' else 'left','item':desired.get(p),'expected':tree.get(p)})
   conflicts=[]
  else:actions,conflicts=plan(l,r,base,req.get('prefer'));restore_source=None
  if conflicts:return {'status':'conflict','conflicts':conflicts,'conflictToken':token,'message':'双方都有修改，未写入任何文件。'}
  if any(s['kind']=='baidu' for s in [leftspec,rightspec]):
   unsupported=[a['path'] for a in actions if a['item'] and (a['item']['type']=='link' or a['item']['type']=='file' and a['item']['size']==0)]
   if unsupported:raise BridgeError('百度网盘连接不支持空文件或符号链接，已在写入前停止：'+', '.join(unsupported[:8]))
  tx=stamp();left.call('checkpoint',tx=tx,phase='before',entries=l);right.call('checkpoint',tx=tx,phase='before',entries=r)
  for side in ['left','right']:
   before_id=tx+'-before-'+side
   atomic_json(directory/(before_id+'.snapshot.json'),{'id':before_id,'snapshotTx':tx,'phase':'before','side':side,'created':time.time(),'reason':('恢复前' if restoring else '同步前')+' · '+('左侧' if side=='left' else '右侧'),'leftRoot':leftspec['root'],'rightRoot':rightspec['root']})
  apply(actions,left,right,tx,restore_source)
  for ep in [left,right]:
   if isinstance(ep,CloudAgent):ep.commit(tx)
  final_l,final_r=left.call('scan'),right.call('scan')
  if {p:signature(x) for p,x in final_l.items()}!={p:signature(x) for p,x in final_r.items()}:raise BridgeError('同步后内容仍不一致，基线未更新；请检查文件是否正在被其他程序修改。')
  left.call('checkpoint',tx=tx,phase='after',entries=final_l);right.call('checkpoint',tx=tx,phase='after',entries=final_r)
  record={'id':tx,'created':time.time(),'reason':'恢复快照' if restoring else '双向同步','leftRoot':leftspec['root'],'rightRoot':rightspec['root']}
  atomic_json(directory/(tx+'.snapshot.json'),record);atomic_json(directory/'baseline.json',{'entries':final_l,'generation':generation,'updated':time.time()})
  return {'status':'ok','operations':len(actions),'snapshot':tx,'files':sum(x['type']=='file' for x in final_l.values()),'recovery':str(state/'recovery'),'message':'两端内容一致，已保存可恢复快照。'}
 finally:
  if left:left.close()
  if right:right.close()
  lock.close()

def agent_loop(spec):
 try:a=Agent(spec['root'],Path.home()/'.local/share/FolderBridge/recovery');print(json.dumps({'ok':True,'version':VERSION}),flush=True)
 except Exception as e:print(json.dumps({'ok':False,'error':str(e)}),flush=True);return
 try:
  for line in sys.stdin:
   try:
    q=json.loads(line);op=q['op']
    if op not in ['scan','list','capabilities','checkpoint','remove','mkdir','begin','chunk','finish','read','read_blob','snapshot']:raise BridgeError('Invalid operation')
    result=a.call(op,**q.get('args',{}));print(json.dumps({'ok':True,'value':result},ensure_ascii=False),flush=True)
   except Exception as e:print(json.dumps({'ok':False,'error':str(e)},ensure_ascii=False),flush=True)
 finally:a.close()

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('mode',choices=['agent','request']);parser.add_argument('--spec');parser.add_argument('--state');args=parser.parse_args()
 if args.mode=='agent':agent_loop(json.loads(base64.urlsafe_b64decode(args.spec)))
 else:
  try:
   request=json.load(sys.stdin);result=main_request(request,Path(args.state).expanduser());print(json.dumps(result,ensure_ascii=False))
  except Exception as e:print(json.dumps({'status':'error','message':str(e)},ensure_ascii=False));sys.exit(1)
