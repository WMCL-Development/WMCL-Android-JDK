public class FontTest {
  public static void main(String[] args) {
    System.setProperty("java.awt.headless", "true");
    try {
      java.awt.Font f = new java.awt.Font("Dialog", java.awt.Font.PLAIN, 12);
      String fam = f.getFamily();
      System.out.println("font-family=" + fam);
      System.out.println("FONT_OK");
    } catch (Throwable t) {
      System.out.println("FONT_FAIL: " + t);
      t.printStackTrace();
    }
  }
}
