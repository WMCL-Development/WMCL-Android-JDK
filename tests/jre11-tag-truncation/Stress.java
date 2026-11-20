import java.lang.reflect.Method;

interface Op { int f(int x); }

class C0 implements Op { public int f(int x) { return x + 1; } }
class C1 implements Op { public int f(int x) { return x + 2; } }
class C2 implements Op { public int f(int x) { return x + 3; } }
class C3 implements Op { public int f(int x) { return x + 4; } }
class C4 implements Op { public int f(int x) { return x + 5; } }
class C5 implements Op { public int f(int x) { return x + 6; } }
class C6 implements Op { public int f(int x) { return x + 7; } }
class C7 implements Op { public int f(int x) { return x + 8; } }
class C8 implements Op { public int f(int x) { return x + 9; } }
class C9 implements Op { public int f(int x) { return x + 10; } }
class C10 implements Op { public int f(int x) { return x + 11; } }
class C11 implements Op { public int f(int x) { return x + 12; } }
class C12 implements Op { public int f(int x) { return x + 13; } }
class C13 implements Op { public int f(int x) { return x + 14; } }
class C14 implements Op { public int f(int x) { return x + 15; } }
class C15 implements Op { public int f(int x) { return x + 16; } }

public class Stress {
  static final Op[] ops = new Op[16];
  static volatile long sink;
  static {
    ops[0] = new C0(); ops[1] = new C1(); ops[2] = new C2(); ops[3] = new C3();
    ops[4] = new C4(); ops[5] = new C5(); ops[6] = new C6(); ops[7] = new C7();
    ops[8] = new C8(); ops[9] = new C9(); ops[10] = new C10(); ops[11] = new C11();
    ops[12] = new C12(); ops[13] = new C13(); ops[14] = new C14(); ops[15] = new C15();
  }

  public static void main(String[] args) throws Exception {
    Thread[] ts = new Thread[6];
    for (int t = 0; t < ts.length; t++) {
      final int id = t;
      ts[t] = new Thread(() -> {
        long s = 0;
        for (int k = 0; k < 500000; k++) {
          Op o = ops[(k + id) & 15];
          s += o.f(k);
          if ((k & 4095) == 0) {
            byte[] garbage = new byte[8192];
            garbage[0] = (byte) k;
            sink += garbage[1];
            if ((k & 65535) == 0) System.gc();
          }
        }
        sink += s;
      });
      ts[t].start();
    }

    Method m = Op.class.getMethod("f", int.class);
    long s2 = 0;
    for (int k = 0; k < 300000; k++) {
      Op o = ops[k & 15];
      s2 += (Integer) m.invoke(o, k);
      if ((k & 8191) == 0) { Object[] g = new Object[64]; g[0] = o; sink += g.length; }
    }
    for (Thread t : ts) t.join();

    long s3 = 0;
    for (int k = 0; k < 30000; k++) {
      Class<?> c = Class.forName("C" + (k & 15));
      s3 += c.getDeclaredMethods().length;
    }
    System.gc();
    System.out.println("stress ok " + (s2 & 1) + " " + (s3 & 1) + " " + (sink & 1));
  }
}
