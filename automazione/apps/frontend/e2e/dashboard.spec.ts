import { expect, test } from '@playwright/test'

test.beforeEach(async ({ page }) => {
  await page.goto('/')
  await expect(page.getByRole('heading', { name: 'Ticket operativi' })).toBeVisible()
})

test('operatore filtra, apre un ticket e consulta il dettaglio', async ({ page }) => {
  await page.getByRole('searchbox', { name: 'Cerca ticket' }).fill('Entra ID')
  await expect(page.getByRole('row', { name: /TKT-2025-0576/ })).toBeVisible()
  await expect(page.getByRole('row', { name: /TKT-2025-0578/ })).toHaveCount(0)

  await page.getByRole('row', { name: /TKT-2025-0576/ }).click()
  await expect(
    page.getByRole('complementary', { name: 'Dettaglio ticket TKT-2025-0576' }),
  ).toBeVisible()
})

test('operatore crea un nuovo ticket', async ({ page }) => {
  await page.getByRole('button', { name: 'Nuovo ticket' }).click()
  const dialog = page.getByRole('dialog', { name: 'Crea nuovo ticket' })
  await dialog.getByLabel('Titolo').fill('Verifica replica database')
  await dialog.getByLabel('Descrizione').fill('La replica deve essere verificata prima del failover.')
  await dialog.getByLabel('Priorità').selectOption('high')
  await dialog.getByLabel('Servizio').selectOption('Database')
  await dialog.getByLabel('Ambiente').selectOption('AWS – Primary')
  await dialog.getByRole('button', { name: 'Crea ticket' }).click()

  await expect(dialog).toHaveCount(0)
  await expect(page.getByRole('row', { name: /Verifica replica database/ })).toBeVisible()
})

test('navigazione e tabella restano utilizzabili su mobile', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.reload()

  await page.getByRole('button', { name: 'Apri navigazione' }).click()
  await expect(page.getByRole('navigation', { name: 'Navigazione principale' })).toBeVisible()
  await page.getByRole('button', { name: 'Chiudi navigazione' }).click()
  await expect(page.getByRole('button', { name: 'Nuovo ticket' })).toBeVisible()
})
