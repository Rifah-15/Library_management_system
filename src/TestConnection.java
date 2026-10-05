import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;

public class TestConnection {

    public static void main(String[] args) {
        try (Connection con = DBConnection.getConnection();
             Statement st = con.createStatement();
             ResultSet rs = st.executeQuery("SELECT BookID, Title FROM Book")) {

            System.out.println("Connected to library_db!");
            while (rs.next()) {
                System.out.println(rs.getInt("BookID") + " - " + rs.getString("Title"));
            }
        } catch (Exception e) {
            System.out.println("Connection failed: " + e.getMessage());
        }
    }
}