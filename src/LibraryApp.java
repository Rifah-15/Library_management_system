import java.awt.BorderLayout;
import java.awt.FlowLayout;
import java.awt.GridLayout;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Vector;
import javax.swing.BorderFactory;
import javax.swing.JButton;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JPasswordField;
import javax.swing.JScrollPane;
import javax.swing.JSpinner;
import javax.swing.JTabbedPane;
import javax.swing.JTable;
import javax.swing.JTextField;
import javax.swing.SpinnerNumberModel;
import javax.swing.SwingUtilities;
import javax.swing.table.DefaultTableModel;

/**
 * Library Management System - works with the ORIGINAL library_db SQL (no schema changes).
 * Business rules that the schema can't hold (fines, renewals, reservation queue,
 * lost/damaged handling, login) are implemented here in Java.
 */
public class LibraryApp extends JFrame {

    // ---- settings (change freely) ----
    private static final BigDecimal FINE_PER_DAY = new BigDecimal("5.00");
    private static final BigDecimal DAMAGE_FEE = new BigDecimal("100.00");
    private static final BigDecimal LOST_FEE = new BigDecimal("300.00");
    private static final int RESERVATION_HOLD_DAYS = 3;

    private static class Item {
        final int id;
        final String label;
        Item(int id, String label) { this.id = id; this.label = label; }
        @Override public String toString() { return label; }
    }

    private interface Action { void run(Connection c) throws SQLException; }

    private final Item staff;

    private final DefaultTableModel booksModel = newModel(), loansModel = newModel(),
            overdueModel = newModel(), resModel = newModel(), fineModel = newModel(),
            memberModel = newModel();
    private final JTable booksTable = new JTable(booksModel), loansTable = new JTable(loansModel),
            resTable = new JTable(resModel), fineTable = new JTable(fineModel),
            memberTable = new JTable(memberModel);

    private final JComboBox<Item> issueMemberBox = new JComboBox<>(), issueCopyBox = new JComboBox<>(),
            resMemberBox = new JComboBox<>(), resBookBox = new JComboBox<>();
    private final JTextField searchField = new JTextField(20);
    private final JLabel dashLabel = new JLabel();

    // =====================================================================
    //  Startup + login (password is set on a staff member's first login)
    // =====================================================================

    public static void main(String[] args) {
        SwingUtilities.invokeLater(() -> {
            Item s = login();
            if (s == null) System.exit(0);
            new LibraryApp(s).setVisible(true);
        });
    }

    private static Item login() {
        JComboBox<Item> box = new JComboBox<>();
        try (Connection c = DBConnection.getConnection();
             Statement st = c.createStatement();
             ResultSet rs = st.executeQuery("SELECT StaffID, Name FROM Staff WHERE AccountStatus='Active' ORDER BY Name")) {
            while (rs.next()) box.addItem(new Item(rs.getInt(1), rs.getString(2)));
        } catch (SQLException ex) {
            JOptionPane.showMessageDialog(null, ex.getMessage(), "Database error", JOptionPane.ERROR_MESSAGE);
            return null;
        }
        JPasswordField pw = new JPasswordField();
        JPanel form = grid("Staff:", box, "Password:", pw);
        while (true) {
            pw.setText("");
            if (JOptionPane.showConfirmDialog(null, form, "Library Login",
                    JOptionPane.OK_CANCEL_OPTION, JOptionPane.PLAIN_MESSAGE) != JOptionPane.OK_OPTION) return null;
            Item s = (Item) box.getSelectedItem();
            if (s == null || pw.getPassword().length == 0) {
                JOptionPane.showMessageDialog(null, "Please enter a password.");
                continue;
            }
            String entered = sha256(new String(pw.getPassword()));
            try (Connection c = DBConnection.getConnection()) {
                Object stored = scalar(c, "SELECT PasswordHash FROM Staff WHERE StaffID=?", s.id);
                if (stored == null || stored.toString().isEmpty()) {
                    exec(c, "UPDATE Staff SET PasswordHash=? WHERE StaffID=?", entered, s.id);
                    JOptionPane.showMessageDialog(null, "First login: this password is now saved for " + s.label + ".");
                    return s;
                }
                if (stored.toString().equals(entered)) return s;
                JOptionPane.showMessageDialog(null, "Wrong password.", "Login", JOptionPane.WARNING_MESSAGE);
            } catch (SQLException ex) {
                JOptionPane.showMessageDialog(null, ex.getMessage(), "Database error", JOptionPane.ERROR_MESSAGE);
            }
        }
    }

    private static String sha256(String s) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (byte b : d) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // =====================================================================
    //  Window
    // =====================================================================

    public LibraryApp(Item staff) {
        super("Library Management System  -  Logged in: " + staff.label);
        this.staff = staff;
        setDefaultCloseOperation(EXIT_ON_CLOSE);
        setSize(1050, 600);
        setLocationRelativeTo(null);

        JTabbedPane tabs = new JTabbedPane();
        tabs.addTab("Dashboard", wrap(dashLabel));
        tabs.addTab("Books", buildBooksPanel());
        tabs.addTab("Issue Book", buildIssuePanel());
        tabs.addTab("Return / Renew", buildLoansPanel());
        tabs.addTab("Reservations", buildReservationPanel());
        tabs.addTab("Fines", buildFinePanel());
        tabs.addTab("Members", buildMemberPanel());
        tabs.addTab("Overdue", tablePanel(new JTable(overdueModel), null, null));
        add(tabs);

        tabs.addChangeListener(e -> refreshAll());
        refreshAll();
    }

    // ---------- panels ----------

    private JPanel buildBooksPanel() {
        JButton search = new JButton("Search"), addBook = new JButton("Add Book"), addCopy = new JButton("Add Copies");
        search.addActionListener(e -> refreshAll());
        searchField.addActionListener(e -> refreshAll());
        addBook.addActionListener(e -> addBook());
        addCopy.addActionListener(e -> addCopies());
        JPanel top = new JPanel(new FlowLayout(FlowLayout.LEFT));
        top.add(new JLabel("Title / author / ISBN / category:"));
        top.add(searchField);
        top.add(search);
        top.add(addBook);
        top.add(addCopy);
        return tablePanel(booksTable, top, null);
    }

    private JPanel buildIssuePanel() {
        JButton issueBtn = new JButton("Issue Book");
        issueBtn.addActionListener(e -> issueBook());
        JPanel form = grid("Member (active only):", issueMemberBox,
                "Book copy (available only):", issueCopyBox,
                "Issued by:", new JLabel(staff.label),
                "", issueBtn);
        JPanel p = new JPanel(new BorderLayout());
        p.setBorder(BorderFactory.createEmptyBorder(30, 40, 30, 40));
        p.add(form, BorderLayout.NORTH);
        return p;
    }

    private JPanel buildLoansPanel() {
        JButton ret = new JButton("Return"), dmg = new JButton("Return (Damaged)"),
                lost = new JButton("Report Lost"), renew = new JButton("Renew");
        ret.addActionListener(e -> returnBook("Good"));
        dmg.addActionListener(e -> returnBook("Damaged"));
        lost.addActionListener(e -> returnBook("Lost"));
        renew.addActionListener(e -> renewLoan());
        return tablePanel(loansTable, null, bar(renew, ret, dmg, lost));
    }

    private JPanel buildReservationPanel() {
        JButton reserve = new JButton("Reserve"), cancel = new JButton("Cancel Selected");
        reserve.addActionListener(e -> reserveBook());
        cancel.addActionListener(e -> cancelReservation());
        JPanel top = new JPanel(new FlowLayout(FlowLayout.LEFT));
        top.add(new JLabel("Member:"));
        top.add(resMemberBox);
        top.add(new JLabel("Book:"));
        top.add(resBookBox);
        top.add(reserve);
        return tablePanel(resTable, top, bar(cancel));
    }

    private JPanel buildFinePanel() {
        JButton pay = new JButton("Pay Selected Fine");
        pay.addActionListener(e -> payFine());
        return tablePanel(fineTable, null, bar(pay));
    }

    private JPanel buildMemberPanel() {
        JButton add = new JButton("Add Member"), toggle = new JButton("Suspend / Activate");
        add.addActionListener(e -> addMember());
        toggle.addActionListener(e -> toggleMember());
        return tablePanel(memberTable, null, bar(add, toggle));
    }

    // =====================================================================
    //  Book actions
    // =====================================================================

    private void addBook() {
        JTextField title = new JTextField(), isbn = new JTextField(), author = new JTextField(),
                publisher = new JTextField(), category = new JTextField(), year = new JTextField(),
                lang = new JTextField("Bengali");
        JSpinner copies = new JSpinner(new SpinnerNumberModel(1, 1, 50, 1));
        JComboBox<Item> shelf = new JComboBox<>();
        loadCombo(shelf, "SELECT ShelfID, CONCAT(Section, ' / ', RackNumber) FROM Shelf ORDER BY Section");
        JPanel f = grid("Title:", title, "ISBN:", isbn, "Author:", author, "Publisher:", publisher,
                "Category:", category, "Year:", year, "Language:", lang, "Copies:", copies, "Shelf:", shelf);
        if (!confirm(f, "Add Book")) return;
        if (title.getText().trim().isEmpty()) { warn("Title is required."); return; }

        final Integer yr;
        try {
            yr = year.getText().trim().isEmpty() ? null : Integer.valueOf(year.getText().trim());
        } catch (NumberFormatException ex) { warn("Year must be a number."); return; }
        Item sh = (Item) shelf.getSelectedItem();

        if (runTx(c -> {
            Long a = findOrCreate(c, "Author", "AuthorID", "Name", author.getText());
            Long p = findOrCreate(c, "Publisher", "PublisherID", "Name", publisher.getText());
            Long cat = findOrCreate(c, "Category", "CategoryID", "CategoryName", category.getText());
            String isbnVal = isbn.getText().trim().isEmpty() ? null : isbn.getText().trim();
            long bookId = insertKey(c,
                "INSERT INTO Book (ISBN, Title, PublisherID, PublicationYear, Language, CategoryID) VALUES (?,?,?,?,?,?)",
                isbnVal, title.getText().trim(), p, yr, lang.getText().trim(), cat);
            if (a != null) exec(c, "INSERT INTO BookAuthor (BookID, AuthorID, AuthorOrder) VALUES (?,?,1)", bookId, a);
            insertCopies(c, bookId, (Integer) copies.getValue(), sh == null ? null : sh.id);
        })) {
            info("Book added.");
            refreshAll();
        }
    }

    private void addCopies() {
        Long bookId = selectedId(booksTable);
        if (bookId == null) return;
        JSpinner copies = new JSpinner(new SpinnerNumberModel(1, 1, 50, 1));
        JComboBox<Item> shelf = new JComboBox<>();
        loadCombo(shelf, "SELECT ShelfID, CONCAT(Section, ' / ', RackNumber) FROM Shelf ORDER BY Section");
        if (!confirm(grid("Number of copies:", copies, "Shelf:", shelf), "Add Copies")) return;
        Item sh = (Item) shelf.getSelectedItem();
        if (runTx(c -> insertCopies(c, bookId, (Integer) copies.getValue(), sh == null ? null : sh.id))) {
            info("Copies added.");
            refreshAll();
        }
    }

    private static void insertCopies(Connection c, long bookId, int n, Integer shelfId) throws SQLException {
        for (int i = 0; i < n; i++) {
            long id = insertKey(c, "INSERT INTO BookCopy (BookID, ShelfID) VALUES (?,?)", bookId, shelfId);
            exec(c, "UPDATE BookCopy SET Barcode=? WHERE CopyID=?", "BC-" + (1000 + id), id);
        }
    }

    private static Long findOrCreate(Connection c, String table, String idCol, String nameCol, String name)
            throws SQLException {
        name = name.trim();
        if (name.isEmpty()) return null;
        Object id = scalar(c, "SELECT " + idCol + " FROM " + table + " WHERE " + nameCol + "=?", name);
        if (id != null) return ((Number) id).longValue();
        return insertKey(c, "INSERT INTO " + table + " (" + nameCol + ") VALUES (?)", name);
    }

    // =====================================================================
    //  Issue / Return / Renew
    // =====================================================================

    private void issueBook() {
        Item member = (Item) issueMemberBox.getSelectedItem();
        Item copy = (Item) issueCopyBox.getSelectedItem();
        if (member == null || copy == null) { warn("Please select a member and a copy."); return; }

        if (run(c -> {
            if (!"Active".equals(scalar(c, "SELECT AccountStatus FROM Member WHERE MemberID=?", member.id)))
                throw new SQLException("This member's account is not active.");
            if (num(c, "SELECT COUNT(*) FROM vw_OverdueBooks v JOIN IssueRecord i ON v.IssueID=i.IssueID WHERE i.MemberID=?", member.id) > 0)
                throw new SQLException("Member has overdue books. Return them first.");
            if (unpaid(c, member.id).signum() > 0)
                throw new SQLException("Member has unpaid fines. Clear them first.");

            long bookId = num(c, "SELECT BookID FROM BookCopy WHERE CopyID=?", copy.id);
            long readyForOthers = num(c, "SELECT COUNT(*) FROM Reservation WHERE BookID=? AND MemberID<>? "
                    + "AND Status='Ready' AND ExpiryDate>=CURDATE()", bookId, member.id);
            long available = num(c, "SELECT COUNT(*) FROM BookCopy WHERE BookID=? AND CopyStatus='Available'", bookId);
            if (available <= readyForOthers)
                throw new SQLException("The remaining copies are held for members who reserved this book.");

            exec(c, "INSERT INTO IssueRecord (CopyID, MemberID, StaffID, IssueDate) VALUES (?,?,?,CURDATE())",
                    copy.id, member.id, staff.id);   // triggers set DueDate, check limit, mark copy Issued
            exec(c, "UPDATE Reservation SET Status='Completed' WHERE MemberID=? AND BookID=? AND Status IN ('Pending','Ready')",
                    member.id, bookId);
        })) {
            info("Book issued successfully.");
            refreshAll();
        }
    }

    private void returnBook(String outcome) {
        Long id = selectedId(loansTable);
        if (id == null) return;
        if (!outcome.equals("Good") && JOptionPane.showConfirmDialog(this,
                "Mark this copy as " + outcome + "? A penalty will be added to the fine.",
                "Confirm", JOptionPane.YES_NO_OPTION) != JOptionPane.YES_OPTION) return;

        BigDecimal[] fineOut = { BigDecimal.ZERO };
        if (runTx(c -> {
            long bookId = num(c, "SELECT bc.BookID FROM IssueRecord i JOIN BookCopy bc ON i.CopyID=bc.CopyID WHERE i.IssueID=?", id);
            if (exec(c, "UPDATE IssueRecord SET Status='Returned' WHERE IssueID=? AND Status='Issued'", id) == 0)
                throw new SQLException("This loan has already been returned.");
            // trigger has set ReturnDate and made the copy Available; fix status if needed
            long late = Math.max(0, num(c, "SELECT DATEDIFF(ReturnDate, DueDate) FROM IssueRecord WHERE IssueID=?", id));
            BigDecimal fine = FINE_PER_DAY.multiply(BigDecimal.valueOf(late));

            if (outcome.equals("Damaged")) {
                exec(c, "UPDATE BookCopy SET CopyStatus='Damaged', ConditionStatus='Damaged' "
                      + "WHERE CopyID=(SELECT CopyID FROM IssueRecord WHERE IssueID=?)", id);
                fine = fine.add(DAMAGE_FEE);
            } else if (outcome.equals("Lost")) {
                exec(c, "UPDATE BookCopy SET CopyStatus='Lost' "
                      + "WHERE CopyID=(SELECT CopyID FROM IssueRecord WHERE IssueID=?)", id);
                fine = fine.add(LOST_FEE);
            } else {
                Object r = scalar(c, "SELECT ReservationID FROM Reservation WHERE BookID=? AND Status='Pending' "
                        + "ORDER BY ReservationDate, ReservationID LIMIT 1", bookId);
                if (r != null)
                    exec(c, "UPDATE Reservation SET Status='Ready', ExpiryDate=DATE_ADD(CURDATE(), INTERVAL ? DAY) "
                          + "WHERE ReservationID=?", RESERVATION_HOLD_DAYS, r);
            }
            // upsert: works whether or not the DB trigger (library_extras.sql) already created the late fine
            if (fine.signum() > 0)
                exec(c, "INSERT INTO Fine (IssueID, Amount) VALUES (?,?) ON DUPLICATE KEY UPDATE Amount=?", id, fine, fine);
            fineOut[0] = fine;
        })) {
            info("Returned successfully." + (fineOut[0].signum() > 0 ? "\nFine charged: " + fineOut[0] : ""));
            refreshAll();
        }
    }

    private void renewLoan() {
        Long id = selectedId(loansTable);
        if (id == null) return;
        if (run(c -> {
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT i.RenewalCount, mt.MaxRenewals, mt.LoanPeriodDays, i.DueDate < CURDATE(), bc.BookID, i.MemberID "
                  + "FROM IssueRecord i JOIN Member m ON i.MemberID=m.MemberID "
                  + "JOIN MemberType mt ON m.MemberTypeID=mt.MemberTypeID "
                  + "JOIN BookCopy bc ON i.CopyID=bc.CopyID WHERE i.IssueID=? AND i.Status='Issued'")) {
                ps.setLong(1, id);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) throw new SQLException("Loan not found or already returned.");
                    if (rs.getInt(1) >= rs.getInt(2))
                        throw new SQLException("Renewal limit reached (" + rs.getInt(2) + " allowed for this member type).");
                    if (rs.getInt(4) == 1)
                        throw new SQLException("This book is overdue and cannot be renewed.");
                    if (num(c, "SELECT COUNT(*) FROM Reservation WHERE BookID=? AND MemberID<>? AND Status IN ('Pending','Ready')",
                            rs.getLong(5), rs.getLong(6)) > 0)
                        throw new SQLException("Another member has reserved this book.");
                    exec(c, "UPDATE IssueRecord SET DueDate=DATE_ADD(DueDate, INTERVAL ? DAY), RenewalCount=RenewalCount+1 "
                          + "WHERE IssueID=?", rs.getInt(3), id);
                }
            }
        })) {
            info("Loan renewed.");
            refreshAll();
        }
    }

    // =====================================================================
    //  Reservations
    // =====================================================================

    private void reserveBook() {
        Item m = (Item) resMemberBox.getSelectedItem(), b = (Item) resBookBox.getSelectedItem();
        if (m == null || b == null) { warn("Select a member and a book."); return; }
        if (run(c -> {
            if (num(c, "SELECT COUNT(*) FROM BookCopy WHERE BookID=? AND CopyStatus='Available'", b.id) > 0)
                throw new SQLException("A copy is available right now - issue it directly instead.");
            exec(c, "INSERT INTO Reservation (BookID, MemberID) VALUES (?,?)", b.id, m.id); // trigger blocks duplicates
        })) {
            info("Reservation placed. It becomes Ready when a copy is returned.");
            refreshAll();
        }
    }

    private void cancelReservation() {
        Long id = selectedId(resTable);
        if (id == null) return;
        if (run(c -> {
            if (exec(c, "UPDATE Reservation SET Status='Cancelled' WHERE ReservationID=? AND Status IN ('Pending','Ready')", id) == 0)
                throw new SQLException("Only Pending or Ready reservations can be cancelled.");
        })) refreshAll();
    }

    // =====================================================================
    //  Fines
    // =====================================================================

    private void payFine() {
        int row = fineTable.getSelectedRow();
        if (row < 0) { warn("Please select a fine first."); return; }
        long fineId = ((Number) fineModel.getValueAt(row, 0)).longValue();
        BigDecimal due = new BigDecimal(fineModel.getValueAt(row, 6).toString());
        if (due.signum() <= 0) { info("This fine is already fully paid."); return; }

        JTextField amount = new JTextField(due.toPlainString());
        JComboBox<String> method = new JComboBox<>(new String[] { "Cash", "bKash", "Card" });
        if (!confirm(grid("Amount (due " + due + "):", amount, "Method:", method), "Pay Fine")) return;
        final BigDecimal paid;
        try {
            paid = new BigDecimal(amount.getText().trim());
        } catch (NumberFormatException ex) { warn("Enter a valid amount."); return; }
        if (paid.signum() <= 0 || paid.compareTo(due) > 0) { warn("Amount must be between 0 and " + due + "."); return; }

        if (run(c -> exec(c, "INSERT INTO FinePayment (FineID, AmountPaid, PaymentMethod, ReferenceNo) VALUES (?,?,?,?)",
                fineId, paid, method.getSelectedItem(), "PAY-" + System.currentTimeMillis()))) {
            info("Payment recorded.");
            refreshAll();
        }
    }

    private static BigDecimal unpaid(Connection c, int memberId) throws SQLException {
        return money(c, "SELECT COALESCE(SUM(f.Amount - COALESCE(p.paid,0)),0) FROM Fine f "
                + "JOIN IssueRecord i ON f.IssueID=i.IssueID "
                + "LEFT JOIN (SELECT FineID, SUM(AmountPaid) AS paid FROM FinePayment GROUP BY FineID) p ON p.FineID=f.FineID "
                + "WHERE i.MemberID=?", memberId);
    }

    // =====================================================================
    //  Members
    // =====================================================================

    private void addMember() {
        JTextField name = new JTextField(), email = new JTextField(), phone = new JTextField(), addr = new JTextField();
        JComboBox<Item> type = new JComboBox<>();
        loadCombo(type, "SELECT MemberTypeID, TypeName FROM MemberType ORDER BY MemberTypeID");
        if (!confirm(grid("Name:", name, "Email:", email, "Phone:", phone, "Address:", addr, "Type:", type), "Add Member")) return;
        if (name.getText().trim().isEmpty()) { warn("Name is required."); return; }
        Item t = (Item) type.getSelectedItem();
        String em = email.getText().trim().isEmpty() ? null : email.getText().trim();
        if (run(c -> exec(c, "INSERT INTO Member (Name, Email, Phone, Address, MemberTypeID) VALUES (?,?,?,?,?)",
                name.getText().trim(), em, phone.getText().trim(), addr.getText().trim(), t.id))) {
            info("Member added.");
            refreshAll();
        }
    }

    private void toggleMember() {
        Long id = selectedId(memberTable);
        if (id == null) return;
        if (run(c -> exec(c, "UPDATE Member SET AccountStatus=IF(AccountStatus='Active','Suspended','Active') WHERE MemberID=?", id)))
            refreshAll();
    }

    // =====================================================================
    //  Loading data
    // =====================================================================

    private void refreshAll() {
        run(c -> exec(c, "UPDATE Reservation SET Status='Cancelled' WHERE Status='Ready' AND ExpiryDate<CURDATE()"));

        String like = "%" + searchField.getText().trim() + "%";
        loadTable(booksModel,
            "SELECT b.BookID, b.ISBN, b.Title, "
          + "  (SELECT GROUP_CONCAT(a.Name SEPARATOR ', ') FROM BookAuthor ba JOIN Author a ON ba.AuthorID=a.AuthorID WHERE ba.BookID=b.BookID) AS Authors, "
          + "  c.CategoryName AS Category, b.PublicationYear AS Year, "
          + "  (SELECT COUNT(*) FROM BookCopy WHERE BookID=b.BookID) AS TotalCopies, "
          + "  (SELECT COUNT(*) FROM BookCopy WHERE BookID=b.BookID AND CopyStatus='Available') AS AvailableCopies "
          + "FROM Book b LEFT JOIN Category c ON b.CategoryID=c.CategoryID "
          + "WHERE b.Title LIKE ? OR b.ISBN LIKE ? OR c.CategoryName LIKE ? OR EXISTS ("
          + "  SELECT 1 FROM BookAuthor ba JOIN Author a ON ba.AuthorID=a.AuthorID WHERE ba.BookID=b.BookID AND a.Name LIKE ?) "
          + "ORDER BY b.BookID", like, like, like, like);

        loadTable(loansModel,
            "SELECT i.IssueID, bc.Barcode, b.Title, m.Name AS Member, i.IssueDate, i.DueDate, "
          + "  i.RenewalCount AS Renewals, GREATEST(DATEDIFF(CURDATE(), i.DueDate), 0) AS DaysLate "
          + "FROM IssueRecord i JOIN BookCopy bc ON i.CopyID=bc.CopyID JOIN Book b ON bc.BookID=b.BookID "
          + "JOIN Member m ON i.MemberID=m.MemberID WHERE i.Status='Issued' ORDER BY i.DueDate");

        loadTable(overdueModel,
            "SELECT *, DaysOverdue * " + FINE_PER_DAY.toPlainString() + " AS EstimatedFine "
          + "FROM vw_OverdueBooks ORDER BY DaysOverdue DESC");

        loadTable(resModel,
            "SELECT r.ReservationID, b.Title, m.Name AS Member, r.ReservationDate, r.ExpiryDate, r.Status "
          + "FROM Reservation r JOIN Book b ON r.BookID=b.BookID JOIN Member m ON r.MemberID=m.MemberID "
          + "ORDER BY FIELD(r.Status,'Ready','Pending','Completed','Cancelled'), r.ReservationID DESC");

        loadTable(fineModel,
            "SELECT f.FineID, m.Name AS Member, b.Title, f.FineDate, f.Amount, COALESCE(p.paid,0) AS Paid, "
          + "  f.Amount - COALESCE(p.paid,0) AS AmountDue "
          + "FROM Fine f JOIN IssueRecord i ON f.IssueID=i.IssueID JOIN Member m ON i.MemberID=m.MemberID "
          + "JOIN BookCopy bc ON i.CopyID=bc.CopyID JOIN Book b ON bc.BookID=b.BookID "
          + "LEFT JOIN (SELECT FineID, SUM(AmountPaid) AS paid FROM FinePayment GROUP BY FineID) p ON p.FineID=f.FineID "
          + "ORDER BY AmountDue DESC, f.FineID DESC");

        loadTable(memberModel,
            "SELECT m.MemberID, m.Name, m.Email, m.Phone, mt.TypeName AS Type, m.AccountStatus AS Status, "
          + "  m.MembershipDate AS Joined, "
          + "  (SELECT COUNT(*) FROM IssueRecord i WHERE i.MemberID=m.MemberID AND i.Status='Issued') AS ActiveLoans "
          + "FROM Member m JOIN MemberType mt ON m.MemberTypeID=mt.MemberTypeID ORDER BY m.MemberID");

        String activeMembers = "SELECT m.MemberID, CONCAT(m.Name, ' (', mt.TypeName, ')') FROM Member m "
                + "JOIN MemberType mt ON m.MemberTypeID=mt.MemberTypeID WHERE m.AccountStatus='Active' ORDER BY m.Name";
        loadCombo(issueMemberBox, activeMembers);
        loadCombo(resMemberBox, activeMembers);
        loadCombo(issueCopyBox, "SELECT bc.CopyID, CONCAT(bc.Barcode, ' - ', b.Title) FROM BookCopy bc "
                + "JOIN Book b ON bc.BookID=b.BookID WHERE bc.CopyStatus='Available' ORDER BY b.Title, bc.Barcode");
        loadCombo(resBookBox, "SELECT BookID, Title FROM Book ORDER BY Title");

        refreshDashboard();
    }

    private void refreshDashboard() {
        run(c -> {
            BigDecimal due = money(c, "SELECT COALESCE((SELECT SUM(Amount) FROM Fine),0) - COALESCE((SELECT SUM(AmountPaid) FROM FinePayment),0)");
            BigDecimal today = money(c, "SELECT COALESCE(SUM(AmountPaid),0) FROM FinePayment WHERE PaymentDate=CURDATE()");
            dashLabel.setText("<html><div style='font-size:15px;line-height:2'>"
                + "<h2>Library Dashboard</h2>"
                + "Book titles: <b>" + num(c, "SELECT COUNT(*) FROM Book") + "</b><br>"
                + "Total copies: <b>" + num(c, "SELECT COUNT(*) FROM BookCopy") + "</b> "
                + "(available: <b>" + num(c, "SELECT COUNT(*) FROM BookCopy WHERE CopyStatus='Available'") + "</b>, "
                + "lost/damaged: <b>" + num(c, "SELECT COUNT(*) FROM BookCopy WHERE CopyStatus IN ('Lost','Damaged')") + "</b>)<br>"
                + "Members: <b>" + num(c, "SELECT COUNT(*) FROM Member") + "</b><br>"
                + "Books currently issued: <b>" + num(c, "SELECT COUNT(*) FROM IssueRecord WHERE Status='Issued'") + "</b><br>"
                + "Overdue loans: <b>" + num(c, "SELECT COUNT(*) FROM vw_OverdueBooks") + "</b><br>"
                + "Active reservations: <b>" + num(c, "SELECT COUNT(*) FROM Reservation WHERE Status IN ('Pending','Ready')") + "</b><br>"
                + "Outstanding fines: <b>" + due + "</b><br>"
                + "Collected today: <b>" + today + "</b>"
                + "</div></html>");
        });
    }

    private void loadTable(DefaultTableModel model, String sql, Object... params) {
        try (Connection c = DBConnection.getConnection();
             PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, params);
            try (ResultSet rs = ps.executeQuery()) {
                ResultSetMetaData md = rs.getMetaData();
                int cols = md.getColumnCount();
                Vector<String> names = new Vector<>();
                for (int i = 1; i <= cols; i++) names.add(md.getColumnLabel(i));
                Vector<Vector<Object>> rows = new Vector<>();
                while (rs.next()) {
                    Vector<Object> row = new Vector<>();
                    for (int i = 1; i <= cols; i++) row.add(rs.getObject(i));
                    rows.add(row);
                }
                model.setDataVector(rows, names);
            }
        } catch (SQLException ex) {
            showError(ex);
        }
    }

    private void loadCombo(JComboBox<Item> box, String sql) {
        try (Connection c = DBConnection.getConnection();
             Statement st = c.createStatement();
             ResultSet rs = st.executeQuery(sql)) {
            box.removeAllItems();
            while (rs.next()) box.addItem(new Item(rs.getInt(1), rs.getString(2)));
        } catch (SQLException ex) {
            showError(ex);
        }
    }

    // =====================================================================
    //  Small helpers
    // =====================================================================

    /** Run DB work on its own connection. Returns true on success; shows the message on failure. */
    private boolean run(Action a) {
        try (Connection c = DBConnection.getConnection()) {
            a.run(c);
            return true;
        } catch (SQLException ex) {
            JOptionPane.showMessageDialog(this, ex.getMessage(), "Cannot complete", JOptionPane.WARNING_MESSAGE);
            return false;
        }
    }

    /** Same, but inside one transaction (all-or-nothing). */
    private boolean runTx(Action a) {
        try (Connection c = DBConnection.getConnection()) {
            c.setAutoCommit(false);
            try {
                a.run(c);
                c.commit();
                return true;
            } catch (SQLException ex) {
                c.rollback();
                throw ex;
            }
        } catch (SQLException ex) {
            JOptionPane.showMessageDialog(this, ex.getMessage(), "Cannot complete", JOptionPane.WARNING_MESSAGE);
            return false;
        }
    }

    private static void bind(PreparedStatement ps, Object... p) throws SQLException {
        for (int i = 0; i < p.length; i++) ps.setObject(i + 1, p[i]);
    }

    private static int exec(Connection c, String sql, Object... p) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, p);
            return ps.executeUpdate();
        }
    }

    private static long insertKey(Connection c, String sql, Object... p) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS)) {
            bind(ps, p);
            ps.executeUpdate();
            try (ResultSet rs = ps.getGeneratedKeys()) {
                rs.next();
                return rs.getLong(1);
            }
        }
    }

    private static Object scalar(Connection c, String sql, Object... p) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            bind(ps, p);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getObject(1) : null;
            }
        }
    }

    private static long num(Connection c, String sql, Object... p) throws SQLException {
        Object o = scalar(c, sql, p);
        return o == null ? 0 : ((Number) o).longValue();
    }

    private static BigDecimal money(Connection c, String sql, Object... p) throws SQLException {
        Object o = scalar(c, sql, p);
        return o == null ? BigDecimal.ZERO : new BigDecimal(o.toString());
    }

    private Long selectedId(JTable t) {
        int row = t.getSelectedRow();
        if (row < 0) { warn("Please select a row from the table first."); return null; }
        return ((Number) t.getValueAt(row, 0)).longValue();
    }

    private boolean confirm(JComponent content, String title) {
        return JOptionPane.showConfirmDialog(this, content, title,
                JOptionPane.OK_CANCEL_OPTION, JOptionPane.PLAIN_MESSAGE) == JOptionPane.OK_OPTION;
    }

    private void warn(String m) { JOptionPane.showMessageDialog(this, m, "Notice", JOptionPane.WARNING_MESSAGE); }
    private void info(String m) { JOptionPane.showMessageDialog(this, m); }
    private void showError(SQLException ex) {
        JOptionPane.showMessageDialog(this, ex.getMessage(), "Database error", JOptionPane.ERROR_MESSAGE);
    }

    /** label/component pairs -> two-column form */
    private static JPanel grid(Object... pairs) {
        JPanel p = new JPanel(new GridLayout(pairs.length / 2, 2, 10, 12));
        for (Object o : pairs) p.add(o instanceof String ? new JLabel((String) o) : (JComponent) o);
        return p;
    }

    private static JPanel bar(JButton... buttons) {
        JPanel p = new JPanel(new FlowLayout(FlowLayout.RIGHT));
        for (JButton b : buttons) p.add(b);
        return p;
    }

    private static JPanel wrap(JComponent c) {
        JPanel p = new JPanel(new BorderLayout());
        p.setBorder(BorderFactory.createEmptyBorder(30, 40, 30, 40));
        p.add(c, BorderLayout.NORTH);
        return p;
    }

    private static JPanel tablePanel(JTable table, JComponent north, JComponent south) {
        JPanel p = new JPanel(new BorderLayout());
        p.setBorder(BorderFactory.createEmptyBorder(10, 10, 10, 10));
        table.setFillsViewportHeight(true);
        p.add(new JScrollPane(table), BorderLayout.CENTER);
        if (north != null) p.add(north, BorderLayout.NORTH);
        if (south != null) p.add(south, BorderLayout.SOUTH);
        return p;
    }

    private static DefaultTableModel newModel() {
        return new DefaultTableModel() {
            @Override public boolean isCellEditable(int row, int column) { return false; }
        };
    }
}